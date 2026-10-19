import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import '../data/models/media_state.dart';
import '../data/models/library_file.dart';
import '../data/models/explore_video.dart';
import '../data/models/stream_urls.dart';
import '../services/storage_service.dart';
import '../services/media_metadata_service.dart';
import '../services/id3_reader.dart';
import '../services/media_source.dart';
import '../services/media_source_resolver.dart';
import '../services/equalizer_service.dart';
import '../services/vibe_grab_audio_handler.dart';
import '../services/session_snapshot.dart';
import '../services/pip_service.dart';

class MediaEngine extends ChangeNotifier implements MediaEngineDelegate {
  final AudioPlayer _player = AudioPlayer();
  VideoPlayerController? _videoController;
  VibeGrabAudioHandler? _audioHandler;
  MediaStatus? _lastLoggedStatus;
  bool? _lastLoggedPlaying;

  // --- Media session self-diagnostic (shown in Settings > About) ---
  // not_run | running | ok | failed: <error>
  String mediaSessionStatus = 'not_run';
  bool? notificationPermission;
  bool _initInFlight = false;
  int _initAttempts = 0;
  // Native truth: NotificationManagerCompat.areNotificationsEnabled() —
  // reflects the Android 13 permission AND the per-app system toggle.
  bool? notificationsEnabledNative;
  // Last platform error swallowed by audio_service (AudioService.asyncError).
  String? lastSessionError;
  // Names of notification drawables missing from the packaged APK.
  String? missingIconDrawables;
  bool _asyncErrorListened = false;
  int? _eqSessionAttached;
  static const MethodChannel _mediaDiagChannel =
      MethodChannel('vibegrab/media_diag');
  final YoutubeExplode _ytc = YoutubeExplode();

  MediaState _state = MediaState();
  MediaState get state => _state;
  bool get hasMedia => _state.hasMedia;
  @override
  bool get isPlaying => _state.isPlaying;
  bool get isVideo => _state.mediaType == MediaType.video;
  bool get hasVideoController => _videoController != null;
  VideoPlayerController? get videoController => _videoController;
  @override
  AudioPlayer get audioPlayer => _player;
  Duration get position => _state.position;
  Duration get duration => _state.duration;

  // --- OS media session snapshot (single source of truth) ---

  final _sessionSnapshots = StreamController<SessionSnapshot>.broadcast();

  @override
  SessionSnapshot get currentSessionSnapshot => SessionSnapshot(
        position: _state.position,
        duration: _state.duration,
        bufferedPosition: _videoController != null
            ? _videoController!.value.buffered.fold<Duration>(
                Duration.zero, (m, r) => r.end > m ? r.end : m)
            : _player.bufferedPosition,
        speed: _speed,
      );

  @override
  Stream<SessionSnapshot> get sessionSnapshots => _sessionSnapshots.stream;

  void _emitSessionSnapshot() {
    if (!_sessionSnapshots.isClosed) {
      _sessionSnapshots.add(currentSessionSnapshot);
    }
  }

  // --- System audio session (focus, interruptions, headphones) ---

  AudioSession? _audioSession;
  final List<StreamSubscription<dynamic>> _audioSessionSubs = [];
  bool _sessionActive = false;
  bool _pausedByInterruption = false;
  bool _ducked = false;
  double _volBeforeDuck = 1.0;
  double _videoVolBeforeDuck = 1.0;

  void _activateAudioSession() {
    if (_sessionActive) return;
    _sessionActive = true;
    _audioSession?.setActive(true).then((ok) {
      if (!ok) debugPrint('[MediaEngine] AudioSession activate refused');
    }).catchError((e) {
      debugPrint('[MediaEngine] AudioSession activate error: $e');
    });
  }

  void _deactivateAudioSession() {
    if (!_sessionActive) return;
    _sessionActive = false;
    _pausedByInterruption = false;
    _audioSession?.setActive(false).catchError((e) {
      debugPrint('[MediaEngine] AudioSession deactivate error: $e');
      return false;
    });
  }

  void _onAudioInterruption(AudioInterruptionEvent event) {
    try {
      if (event.begin) {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _setDucking(true);
            break;
          case AudioInterruptionType.pause:
            if (isPlaying) {
              _pausedByInterruption = true;
              pause();
            }
            break;
          case AudioInterruptionType.unknown:
            if (isPlaying) {
              _pausedByInterruption = true;
              pause();
            }
            break;
        }
      } else {
        switch (event.type) {
          case AudioInterruptionType.duck:
            _setDucking(false);
            break;
          case AudioInterruptionType.pause:
            if (_pausedByInterruption) {
              _pausedByInterruption = false;
              resume();
            }
            break;
          case AudioInterruptionType.unknown:
            // System interruption (e.g. call) ended: stay paused and let
            // the user resume manually from app, notification or headset.
            _pausedByInterruption = false;
            break;
        }
      }
    } catch (e) {
      debugPrint('[MediaEngine] Interruption handling error: $e');
    }
  }

  Future<void> _setDucking(bool duck) async {
    try {
      if (duck && !_ducked) {
        _ducked = true;
        _volBeforeDuck = _player.volume;
        _videoVolBeforeDuck = _videoController?.value.volume ?? 1.0;
        await _player.setVolume(_volBeforeDuck * 0.25);
        await _videoController?.setVolume(_videoVolBeforeDuck * 0.25);
      } else if (!duck && _ducked) {
        _ducked = false;
        await _player.setVolume(_volBeforeDuck);
        await _videoController?.setVolume(_videoVolBeforeDuck);
      }
    } catch (e) {
      debugPrint('[MediaEngine] Ducking error: $e');
    }
  }

  bool _isAudioBackgroundActive = false;
  bool get isAudioBackgroundActive => _isAudioBackgroundActive;

  /// True between [onScreenOff] and [onScreenOn]. The handoff checks it after
  /// every await: if the screen came back while the audio source was being
  /// prepared, the video must stay alive instead of going silent behind a
  /// resumed UI.
  bool _appInBackground = false;

  /// Audio-only source resolved while the video was still on screen. The
  /// screen-off handoff must not start a network request after the app has
  /// been backgrounded: the OS may freeze the isolate mid-resolve, which is
  /// silence with the UI still claiming playback.
  AudioSource? _warmAudioSource;
  String? _warmAudioMediaId;

  StreamSubscription<PlaybackEvent>? _errSub;

  /// Set by [dispose]: an in-flight thumbnail write must not notify a
  /// ChangeNotifier that no longer has listeners.
  bool _disposed = false;

  bool _isInPiP = false;
  bool _isPiPEntering = false;
  DateTime? pipExitedAt;
  Timer? _pipConfirmTimer;
  Timer? _playWatchdog;
  String? playbackError;
  String? _lastVideoError;
  String? _lastAudioError;
  String? _lastStreamError;
  bool get isInPiP => _isInPiP || _isPiPEntering;

  double get progress {
    if (_state.duration.inMilliseconds <= 0) return 0.0;
    final v =
        _state.position.inMilliseconds / _state.duration.inMilliseconds;
    if (!v.isFinite) return 0.0;
    return v.clamp(0.0, 1.0);
  }

  String get positionFormatted => _formatDuration(_state.position);
  String get durationFormatted => _formatDuration(_state.duration);
  String? get currentMediaId => _state.mediaId;
  String? get currentTitle => _state.title;
  String? get currentArtist => _state.artist;
  String? get currentThumbnail => _state.thumbnail;
  String? get currentThumbnailPath => _state.thumbnailPath;

  final List<MediaItem> _queue = [];
  List<MediaItem> get queue => List.unmodifiable(_queue);
  int _currentIndex = -1;
  int get currentIndex => _currentIndex;
  bool get hasNext {
    if (_queue.isEmpty) return false;
    if (_state.isShuffle) return _shuffleHasNext;
    return _currentIndex < _queue.length - 1 ||
        _state.repeatMode == PlayerRepeatMode.all;
  }

  bool get hasPrevious {
    if (_queue.isEmpty) return false;
    if (_state.isShuffle) return _shuffleHasPrevious;
    return _currentIndex > 0 ||
        _state.repeatMode == PlayerRepeatMode.all;
  }
  bool _completionHandled = false;
  static const _prefix = 'vibegrab_metadata_';
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  Timer? _completionDebounce;

  String _formatDuration(Duration d) {
    if (d.inMilliseconds <= 0) return '--:--';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    if (minutes == 0 && seconds == 0) return '--:--';
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _loadPosition(String mediaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt('$_prefix${mediaId}_pos') ?? 0;
      _state = _state.copyWith(position: Duration(milliseconds: ms));
    } catch (_) {}
  }

  /// Resume-position writes are throttled. The player emits position at
  /// ~10Hz and every tick used to be a SharedPreferences platform-channel
  /// round trip (a real write to disk) for a value that only matters every
  /// few seconds. [force] (stop / seek / handoff) always writes at once.
  static const _positionSaveInterval = Duration(seconds: 2);
  String? _pendingPositionId;
  Duration _pendingPosition = Duration.zero;
  DateTime _lastPositionSave = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _savePosition(String mediaId, Duration position,
      {bool force = false}) async {
    // A player stop/reconnect emits a ~0 blip; persisting it would
    // clobber a valid resume point. Explicit seeks bypass this.
    if (!force && position < const Duration(milliseconds: 500)) return;
    _pendingPositionId = mediaId;
    _pendingPosition = position;
    final now = DateTime.now();
    if (!force && now.difference(_lastPositionSave) < _positionSaveInterval) {
      return;
    }
    _lastPositionSave = now;
    final id = _pendingPositionId!;
    final ms = _pendingPosition.inMilliseconds;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$_prefix${id}_pos', ms);
    } catch (_) {}
  }

  Future<void> clearResumePosition(String mediaId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix${mediaId}_pos');
  }

  Uri? _resolvePlaybackUri(LibraryFile file) {
    if (file.hasContentUri) {
      return Uri.parse(file.contentUri!);
    }
    final candidate = Uri.tryParse(file.filename);
    if (candidate != null && (candidate.scheme == 'http' || candidate.scheme == 'https')) {
      return candidate;
    }
    final localFile = StorageService.instance.getFile(file.filename);
    if (localFile != null) {
      return Uri.file(localFile.path);
    }
    return null;
  }

  Uri? _resolveArtUri(LibraryFile file) {
    if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
      final imgFile = File(file.thumbnailPath!);
      if (imgFile.existsSync()) {
        return Uri.file(imgFile.path);
      }
    }
    if (file.thumbnail != null && file.thumbnail!.isNotEmpty) {
      return Uri.tryParse(file.thumbnail!);
    }
    return null;
  }

  /// Writes a local file's embedded cover into the cache once and returns it.
  ///
  /// The name carries the size and modification time, so replacing the file
  /// produces a fresh cover instead of a stale one, while repeat plays reuse
  /// the same bytes.
  Future<File?> _writeCoverToCache(File source, AudioTags tags) async {
    final picture = tags.picture;
    if (picture == null || picture.isEmpty) return null;
    try {
      final stat = await source.stat();
      final dir =
          Directory('${(await getTemporaryDirectory()).path}/vibegrab_covers');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = (tags.pictureMime ?? '').contains('png') ? 'png' : 'jpg';
      final stamp = '${source.path.hashCode.toRadixString(16)}'
          '_${stat.size}_${stat.modified.millisecondsSinceEpoch}';
      final out = File('${dir.path}/$stamp.$ext');
      if (!await out.exists()) {
        await out.writeAsBytes(picture, flush: true);
      }
      return out;
    } catch (e) {
      debugPrint('[MediaEngine] cover cache failed: $e');
      return null;
    }
  }

  /// Media id whose remote thumbnail has already been requested.
  String? _thumbCacheKey;

  /// Downloads the remote thumbnail once so the mini player, the audio sheet
  /// and the detail page can paint it from disk.
  ///
  /// `Image.network` on its own is what produced the grey square every time
  /// the player was minimized: the widget was rebuilt with an empty image
  /// cache and had nothing to show until the HTTP response arrived. A local
  /// file paints in the same frame, survives a rebuild and works offline.
  void _cacheThumbnailIfNeeded() {
    final remote = _state.thumbnail;
    if (remote == null || remote.isEmpty) return;
    if (!remote.startsWith('http')) return;
    if (_thumbCacheKey == remote) return;

    final existing = _state.thumbnailPath;
    if (existing != null && existing.isNotEmpty && File(existing).existsSync()) {
      return;
    }
    _thumbCacheKey = remote;
    unawaited(_downloadThumbnail(remote));
  }

  Future<void> _downloadThumbnail(String remote) async {
    final uri = Uri.tryParse(remote);
    if (uri == null || !uri.hasAuthority) return;
    try {
      final dir = Directory(
          '${(await getTemporaryDirectory()).path}/vibegrab_thumbs');
      if (!await dir.exists()) await dir.create(recursive: true);
      final lower = uri.path.toLowerCase();
      final ext = lower.endsWith('.png')
          ? 'png'
          : lower.endsWith('.webp')
              ? 'webp'
              : 'jpg';
      final file = File(
          '${dir.path}/${remote.hashCode.toRadixString(16)}_${remote.length}.$ext');

      if (!await file.exists() || await file.length() == 0) {
        final client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        IOSink? sink;
        try {
          final request = await client.getUrl(uri);
          request.headers.set('User-Agent', ApiConfig.streamUserAgent);
          final response =
              await request.close().timeout(const Duration(seconds: 15));
          if (response.statusCode == 200) {
            sink = file.openWrite();
            var bytes = 0;
            await for (final chunk
                in response.timeout(const Duration(seconds: 15))) {
              bytes += chunk.length;
              // Thumbnails are small; anything larger is not one.
              if (bytes > 4 * 1024 * 1024) break;
              sink.add(chunk);
            }
            await sink.close();
            sink = null;
            if (bytes == 0 && await file.exists()) {
              await file.delete();
            }
          } else {
            await response.drain<void>();
          }
        } finally {
          if (sink != null) await sink.close();
          client.close(force: true);
        }
      }

      if (!await file.exists() || await file.length() == 0) return;
      // The user may have moved on while the download was in flight.
      if (_state.thumbnail != remote) return;
      if (_disposed) return;
      _state = _state.copyWith(thumbnailPath: file.path);
      _emitSessionSnapshot();
      _syncPlaybackStateToHandler();
      notifyListeners();
    } catch (e) {
      debugPrint('[MediaEngine] thumbnail cache failed: ${e.runtimeType}');
    }
  }

  /// Extracts YouTube video ID from various URL formats.
  /// Supports: youtube.com/watch?v=ID, youtu.be/ID, youtube.com/shorts/ID,
  /// youtube.com/embed/ID, youtube.com/v/ID, youtube.com/shorts/ID,
  /// and URLs with additional parameters.
  /// Handles URLs with spaces, special characters, and various formats.
  String? _parseVideoIdFromUrl(String url) {
    final sanitized = url.trim();
    if (sanitized.isEmpty) return null;

    final uri = Uri.tryParse(sanitized);
    final host = uri?.host.toLowerCase() ?? '';
    // Only real YouTube hosts may yield an id: a regex hit inside a
    // TikTok/Instagram link (e.g. a `v=` query) would drag foreign links
    // into the YouTube pipeline instead of the external one.
    final isYouTubeHost =
        host.contains('youtube.com') || host.contains('youtu.be');
    if (uri != null && host.isNotEmpty && !isYouTubeHost) return null;

    // First try the regex for common patterns
    final idMatch = RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/|/embed/|/v/)([A-Za-z0-9_-]{11})').firstMatch(sanitized);
    if (idMatch != null) return idMatch.group(1);
    
    if (uri == null) return null;
    
    final isYouTube = isYouTubeHost;
    
    if (!isYouTube) return null;
    
    // Handle youtu.be/VIDEO_ID
    if (uri.host.contains('youtu.be')) {
      final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
      if (id != null && id.length == 11) return id;
    }
    
    // Check for 'v' query parameter
    final vParam = uri.queryParameters['v'];
    if (vParam != null && vParam.length == 11) return vParam;
    
    // Handle /shorts/VIDEO_ID
    if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'shorts') {
      final id = uri.pathSegments.last;
      if (id.length == 11) return id;
    }
    
    // Handle /embed/VIDEO_ID
    if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'embed') {
      final id = uri.pathSegments.last;
      if (id.length == 11) return id;
    }
    
    // Handle /v/VIDEO_ID
    if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'v') {
      final id = uri.pathSegments.last;
      if (id.length == 11) return id;
    }
    
    // Check for 'vi' path parameter
    if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'vi') {
      final id = uri.pathSegments.last;
      if (id.length == 11) return id;
    }
    
    // Check for 'vi' path parameter
    if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'vi') {
      final id = uri.pathSegments.last;
      if (id.length == 11) return id;
    }
    
    // Check for 'si' parameter (shared videos)
    final siParam = uri.queryParameters['si'];
    if (siParam != null && siParam.length == 11) return siParam;
    
    return null;
  }

  LibraryFile? _resolveLibraryFileFromExtras(Map<String, dynamic>? extras) {
    if (extras == null) return null;
    final fileJson = extras['libraryFile'];
    if (fileJson == null) return null;
    try {
      if (fileJson is String) {
        return LibraryFile.fromJson(jsonDecode(fileJson));
      } else if (fileJson is Map) {
        return LibraryFile.fromJson(Map<String, dynamic>.from(fileJson));
      }
    } catch (_) {}
    return null;
  }

  // --- AudioService Integration ---

  Future<void> initAudioService({bool force = false}) async {
    if (_initInFlight) return;
    if (!force &&
        (mediaSessionStatus == 'ok' || mediaSessionStatus == 'running')) {
      return;
    }
    _initInFlight = true;
    mediaSessionStatus = 'running';
    notifyListeners();
    // audio_service forwards every platform failure (setState NPE,
    // ForegroundServiceStartNotAllowedException, ...) into asyncError and
    // swallows it. Surface it so the diagnostic tile can never lie.
    if (!_asyncErrorListened) {
      _asyncErrorListened = true;
      AudioService.asyncError.listen((e) {
        lastSessionError = '$e';
        debugPrint('[MEDIA_SESSION] asyncError: $e');
        notifyListeners();
      });
    }
    try {
      debugPrint(
          '[MEDIA_SESSION] Initializing AudioService (attempt ${_initAttempts + 1})...');
      // Android 13+: the media notification needs POST_NOTIFICATIONS.
      try {
        notificationPermission = await Permission.notification.isGranted;
        if (notificationPermission != true) {
          await Permission.notification.request();
          notificationPermission = await Permission.notification.isGranted;
        }
      } catch (e) {
        debugPrint('[MEDIA_SESSION] Notification permission check failed: $e');
      }
      // Real system state (covers OEM per-app notification toggles too).
      try {
        notificationsEnabledNative =
            await _mediaDiagChannel.invokeMethod<bool>('notificationsEnabled');
      } catch (e) {
        debugPrint('[MEDIA_SESSION] Native notification check failed: $e');
      }
      // Proof that the name-resolved drawables really shipped in the APK.
      // Missing icons (id 0) are why the media notification could never be
      // posted before; surface it instead of failing silently.
      try {
        final ids = await _mediaDiagChannel
            .invokeMethod<Map<Object?, Object?>>('mediaDrawableIds');
        if (ids != null) {
          final missing = <String>[];
          ids.forEach((k, v) {
            debugPrint('[MEDIA_SESSION] drawable $k = $v');
            if ((v as int?) == 0) missing.add('$k');
          });
          missingIconDrawables = missing.isEmpty ? null : missing.join(', ');
        }
      } catch (e) {
        debugPrint('[MEDIA_SESSION] Drawable check failed: $e');
      }
      PiPService.init();
      _audioHandler ??= VibeGrabAudioHandler(this);
      // AudioServiceActivity provides the shared engine (required so the
      // plugin accepts this engine); the Dart side is initialized HERE.
      if (!_isAudioServiceInitialized()) {
        await AudioService.init(
          builder: () => _audioHandler!,
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.example.vibegrab.audio',
            androidNotificationChannelName: 'VibeGrab Audio',
            androidNotificationChannelDescription: 'VibeGrab media playback controls',
            androidNotificationIcon: 'drawable/ic_music_note',
            // Android 12+: restarting the FGS from the background (system
            // play button while app is backgrounded) throws
            // ForegroundServiceStartNotAllowedException. Keeping the service
            // foreground across a pause avoids that and keeps the media
            // session + notification available while paused (audio_service
            // README advice). The FGS notification itself is not dismissable
            // while the service is in the foreground.
            androidNotificationOngoing: false,
            androidStopForegroundOnPause: false,
            preloadArtwork: true,
          ),
        ).timeout(const Duration(seconds: 10));
      }
      _setupAudioSession();
      mediaSessionStatus = 'ok';
      lastSessionError = null;
      debugPrint('[MEDIA_SESSION] Service started (AudioService.init ok)');
    } catch (e) {
      mediaSessionStatus = 'failed: $e';
      debugPrint('[MEDIA_SESSION] Service init FAILED: $e');
      if (_initAttempts < 3) {
        _initAttempts++;
        final delay = Duration(seconds: 2 * _initAttempts);
        debugPrint(
            '[MEDIA_SESSION] Retrying in ${delay.inSeconds}s (attempt ${_initAttempts + 1})');
        Future.delayed(delay, () => initAudioService(force: true));
      }
    } finally {
      _initInFlight = false;
      notifyListeners();
    }
  }

  Future<void> _setupAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.duckOthers,
        androidAudioAttributes: AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
      ));
      _audioSession = session;
      _audioSessionSubs
        ..add(session.interruptionEventStream.listen(_onAudioInterruption))
        ..add(session.becomingNoisyEventStream.listen((_) {
          debugPrint('[MediaEngine] Audio becoming noisy -> pause');
          if (isPlaying) pause();
        }));
      debugPrint('[MediaEngine] AudioSession configured');
    } catch (e) {
      debugPrint('[MediaEngine] AudioSession setup failed: $e');
    }
  }

  bool _isAudioServiceInitialized() {
    try {
      final _ = AudioService.config;
      return true;
    } catch (_) {
      return false;
    }
  }

  void _syncToAudioHandler(MediaItem item) {
    debugPrint('[MediaEngine] Syncing to handler: ${item.title}, artUri=${item.artUri}');
    // First play is the moment where the system session MUST be connected:
    // retry initialization here if it is not ok yet.
    if (mediaSessionStatus != 'ok') {
      initAudioService();
    }
    _audioHandler?.updateMediaItem(item);
    _applyDefaultArtIfNeeded(item);
    _syncPlaybackStateToHandler();
  }

  // --- Default artwork (notification cover when none exists) ---

  Future<Uri?>? _defaultArtUri;

  /// Materializes assets/media_placeholder.png into the app documents
  /// directory once, so Android can load it as a real file bitmap.
  Future<Uri?> _ensureDefaultArt() {
    return _defaultArtUri ??= () async {
      try {
        final bytes = await rootBundle.load('assets/media_placeholder.png');
        final dir = await getApplicationDocumentsDirectory();
        final file = File('${dir.path}/media_placeholder.png');
        if (!await file.exists() ||
            await file.length() != bytes.lengthInBytes) {
          await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        }
        debugPrint('[MEDIA_SESSION] Default artwork materialized');
        return Uri.file(file.path);
      } catch (e) {
        debugPrint('[MEDIA_SESSION] Default artwork failed: $e');
        return null;
      }
    }();
  }

  /// If the item has no cover yet, attach the default artwork as soon as it
  /// is materialized (data may arrive after playback started).
  void _applyDefaultArtIfNeeded(MediaItem item) {
    if (item.artUri != null) return;
    _ensureDefaultArt().then((uri) {
      if (uri == null) return;
      final current = _audioHandler?.mediaItem.value;
      if (current != null &&
          current.id == item.id &&
          current.artUri == null) {
        debugPrint('[MEDIA_SESSION] MediaItem art filled with default');
        _audioHandler?.updateMediaItem(current.copyWith(artUri: uri));
      }
    }).catchError((_) {});
  }

  void _syncPlaybackStateToHandler() {
    _cacheThumbnailIfNeeded();
    AudioProcessingState procState;
    switch (_state.status) {
      case MediaStatus.idle:
        // audio_service tears down the Android media session (stops the
        // foreground service and CANCELS the notification) the instant it
        // sees processingState=idle. Mid-flow idles (stop-current before a
        // new load, error fallbacks, player restarts) must NOT do that:
        // report paused so the system media card/notification survives.
        // Real teardown still works: the handler's stop() pushes idle
        // directly, and a cold app (no media yet) keeps genuine idle.
        procState = _state.hasMedia
            ? AudioProcessingState.ready
            : AudioProcessingState.idle;
        break;
      case MediaStatus.loading:
        procState = AudioProcessingState.loading;
        break;
      case MediaStatus.buffering:
        procState = AudioProcessingState.buffering;
        break;
      case MediaStatus.playing:
        procState = AudioProcessingState.ready;
        break;
      case MediaStatus.paused:
        procState = AudioProcessingState.ready;
        break;
      case MediaStatus.completed:
        procState = AudioProcessingState.completed;
        break;
    }
    debugPrint('[MediaEngine] Sync playback state: playing=${_state.isPlaying}, status=${_state.status.name}, handler=${_audioHandler != null}');
    if (kDebugMode && (_state.status != _lastLoggedStatus || _state.isPlaying != _lastLoggedPlaying)) {
      _lastLoggedStatus = _state.status;
      _lastLoggedPlaying = _state.isPlaying;
      debugPrint('[MEDIA_SESSION] PlaybackState updated: playing=${_state.isPlaying}, state=${_state.status.name}');
    }
    _audioHandler?.updatePlaybackState(
      playing: _state.isPlaying,
      processingState: procState,
      repeatMode: _state.repeatMode,
      shuffle: _state.isShuffle,
    );
    _emitSessionSnapshot();
    if (_state.isPlaying) {
      _activateAudioSession();
      // Keep the DSP equalizer glued to the current output: audio uses the
      // player's session, video uses the output mix (session 0).
      final sid = isVideo ? 0 : (_player.androidAudioSessionId ?? 0);
      if (sid != _eqSessionAttached) {
        _eqSessionAttached = sid;
        EqualizerService.instance.ensureReady(sid);
      }
    } else if (procState == AudioProcessingState.idle) {
      _deactivateAudioSession();
    }
  }

  void _syncQueueToHandler() {
    _audioHandler?.queue.add(_queue);
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      _audioHandler?.updateMediaItem(_queue[_currentIndex]);
      _applyDefaultArtIfNeeded(_queue[_currentIndex]);
    }
  }

  // --- Queue Management ---

  void setQueue(List<MediaItem> items, {int startIndex = 0}) {
    _queue.clear();
    _queue.addAll(items);
    _currentIndex = startIndex;
    _syncQueueToHandler();
    notifyListeners();
  }

  void setQueueFromFiles(List<LibraryFile> files, {int startIndex = 0}) {
    _queue.clear();
    for (final file in files) {
      _queue.add(_libraryFileToMediaItem(file));
    }
    _currentIndex = startIndex.clamp(0, _queue.length - 1);
    _syncQueueToHandler();
    notifyListeners();
  }

  MediaItem _libraryFileToMediaItem(LibraryFile file) {
    final id = file.hasContentUri ? file.contentUri! : file.filename;
    final artUri = _resolveArtUri(file);
    return MediaItem(
      id: id,
      title: file.title,
      artist: file.source ?? 'VibeGrab',
      album: file.album,
      artUri: artUri,
      duration: file.durationMs != null ? Duration(milliseconds: file.durationMs!) : null,
      extras: {
        'fileType': file.fileType,
        'filePath': file.filePath,
        'filename': file.filename,
        'libraryFile': jsonEncode(file.toJson()),
      },
    );
  }

  MediaItem _exploreVideoToMediaItem(ExploreVideo video) {
    final artUri = video.thumbnail != null ? Uri.tryParse(video.thumbnail!) : null;
    final secs = video.duration ?? _parseDurationString(video.durationString);
    return MediaItem(
      id: video.url,
      title: video.title,
      artist: video.channel ?? 'YouTube',
      artUri: artUri,
      duration: secs != null ? Duration(seconds: secs) : null,
      // isVideo routes the queue item through the video pipeline instead of
      // the audio-only shortcut (same MediaEngine, same AudioHandler).
      extras: <String, dynamic>{
        'isVideo': true,
        'provider': video.provider,
        if (video.channelId != null) 'channelId': video.channelId,
      },
    );
  }

  /// Parses "04:27" / "1:59:06" labels into seconds. Search results often
  /// carry the label but not the numeric duration; without this the player
  /// shows 00:00 and seeking is impossible.
  int? _parseDurationString(String? s) {
    if (s == null) return null;
    final parts = s.trim().split(':');
    int? p(String x) => int.tryParse(x);
    if (parts.length == 2) {
      final m = p(parts[0]);
      final sec = p(parts[1]);
      if (m != null && sec != null) return m * 60 + sec;
    } else if (parts.length == 3) {
      final h = p(parts[0]);
      final m = p(parts[1]);
      final sec = p(parts[2]);
      if (h != null && m != null && sec != null) {
        return h * 3600 + m * 60 + sec;
      }
    }
    return null;
  }

  MediaItem _createMediaItemFromState() {
    final item = _queue.isNotEmpty && _currentIndex >= 0 && _currentIndex < _queue.length
        ? _queue[_currentIndex]
        : null;
    return MediaItem(
      id: _state.mediaId ?? '',
      title: _state.title ?? 'Unknown',
      artist: _state.artist ?? 'VibeGrab',
      artUri: _state.thumbnailPath != null
          ? Uri.file(_state.thumbnailPath!)
          : (_state.thumbnail != null ? Uri.tryParse(_state.thumbnail!) : null),
      duration: _state.duration,
      extras: item?.extras,
    );
  }

  void addToQueue(MediaItem item) {
    _queue.add(item);
    _syncQueueToHandler();
    notifyListeners();
  }

  /// Queues an Explorer result without interrupting what is playing.
  void addToQueueExplore(ExploreVideo video) {
    _queue.add(_exploreVideoToMediaItem(video));
    _syncQueueToHandler();
    notifyListeners();
  }

  void removeFromQueue(int index) {
    if (index < 0 || index >= _queue.length) return;
    _queue.removeAt(index);
    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex && _currentIndex >= _queue.length) {
      _currentIndex = _queue.length - 1;
    }
    _syncQueueToHandler();
    notifyListeners();
  }

  void clearQueue() {
    _queue.clear();
    _currentIndex = -1;
    _audioHandler?.queue.add([]);
    notifyListeners();
  }

  // --- Shuffle & Repeat (ONE global playback mode) ---
  //
  // The mode button cycles: normal -> repeat-all -> repeat-one -> shuffle.
  // Shuffle keeps a permutation of the queue so every track plays once per
  // run (no A → A → A), and the same logic drives local, Explorer,
  // notification, queue UI, completion and manual skips.

  List<int> _shuffleOrder = [];
  int _shufflePos = -1;
  bool _playModeLoaded = false;

  /// Restores the persisted repeat/shuffle mode (call once at startup).
  Future<void> loadPlayMode() async {
    if (_playModeLoaded) return;
    _playModeLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ri = prefs.getInt('${_prefix}playmode_repeat') ?? 0;
      final mode = PlayerRepeatMode.values[ri.clamp(0, PlayerRepeatMode.values.length - 1)];
      final shuffle = prefs.getBool('${_prefix}playmode_shuffle') ?? false;
      _state = _state.copyWith(repeatMode: mode, isShuffle: shuffle);
      _applyLoopMode(mode);
      if (shuffle) _rebuildShuffleOrder();
      debugPrint('[MediaEngine] Restored play mode: $mode shuffle=$shuffle');
    } catch (_) {}
  }

  Future<void> _savePlayMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_prefix}playmode_repeat', _state.repeatMode.index);
      await prefs.setBool('${_prefix}playmode_shuffle', _state.isShuffle);
    } catch (_) {}
  }

  void _applyLoopMode(PlayerRepeatMode mode) {
    switch (mode) {
      case PlayerRepeatMode.none:
        _player.setLoopMode(LoopMode.off);
        break;
      case PlayerRepeatMode.one:
        _player.setLoopMode(LoopMode.one);
        break;
      case PlayerRepeatMode.all:
        _player.setLoopMode(LoopMode.all);
        break;
    }
  }

  /// Applies a repeat+shuffle combination and persists it.
  @override
  void setPlayMode(PlayerRepeatMode mode, bool shuffle) {
    _state = _state.copyWith(repeatMode: mode, isShuffle: shuffle);
    // Engine-level shuffle owns the order; just_audio's internal shuffle
    // must stay off so manual queue navigation is never contradicted.
    _player.setShuffleModeEnabled(false);
    _applyLoopMode(mode);
    if (shuffle) {
      _rebuildShuffleOrder();
    } else {
      _shuffleOrder = [];
      _shufflePos = -1;
    }
    _savePlayMode();
    _syncPlaybackStateToHandler();
    notifyListeners();
    _audioHandler?.refreshControls();
  }

  /// The mode button cycle: normal -> all -> one -> shuffle -> normal.
  @override
  void cyclePlayMode() {
    if (_state.repeatMode == PlayerRepeatMode.none && !_state.isShuffle) {
      setPlayMode(PlayerRepeatMode.all, false);
    } else if (_state.repeatMode == PlayerRepeatMode.all && !_state.isShuffle) {
      setPlayMode(PlayerRepeatMode.one, false);
    } else if (_state.repeatMode == PlayerRepeatMode.one && !_state.isShuffle) {
      setPlayMode(PlayerRepeatMode.none, true);
    } else {
      setPlayMode(PlayerRepeatMode.none, false);
    }
  }

  void toggleShuffle() {
    // Standalone shuffle toggle (keeps the current repeat setting).
    setPlayMode(_state.repeatMode, !_state.isShuffle);
  }

  void toggleRepeat() {
    // Kept for compatibility: the mode button uses cyclePlayMode().
    cyclePlayMode();
  }

  /// Rebuilds the shuffled run anchored at the current item.
  void _rebuildShuffleOrder() {
    final n = _queue.length;
    if (n == 0) {
      _shuffleOrder = [];
      _shufflePos = -1;
      return;
    }
    _shuffleOrder = List<int>.generate(n, (i) => i)..shuffle();
    final ci = _currentIndex.clamp(0, n - 1);
    _shuffleOrder.remove(ci);
    _shuffleOrder.insert(0, ci);
    _shufflePos = 0;
  }

  /// Self-heals the shuffle order after ANY external queue/index change
  /// (playFile, playUrl, setQueue, removals...) without touching those paths:
  /// if the current item is still in the run, continue from it; otherwise
  /// rebuild a fresh run anchored at the current item.
  void _ensureShuffleOrder() {
    final n = _queue.length;
    final ok = _shuffleOrder.length == n &&
        n > 0 &&
        _shuffleOrder.toSet().length == n;
    if (!ok) {
      _rebuildShuffleOrder();
      return;
    }
    if (_shufflePos < 0 ||
        _shufflePos >= n ||
        _shuffleOrder[_shufflePos] != _currentIndex) {
      final p = _shuffleOrder.indexOf(_currentIndex);
      if (p >= 0) {
        _shufflePos = p;
      } else {
        _rebuildShuffleOrder();
      }
    }
  }

  /// Next index inside the shuffled run, or null when the run is exhausted
  /// and repeat-all is off.
  int? _shuffleAdvance() {
    if (_queue.length <= 1) return null;
    _ensureShuffleOrder();
    if (_shufflePos + 1 < _shuffleOrder.length) {
      _shufflePos++;
      return _shuffleOrder[_shufflePos];
    }
    if (_state.repeatMode == PlayerRepeatMode.all) {
      _rebuildShuffleOrder();
      if (_shuffleOrder.length > 1) {
        _shufflePos = 1;
        return _shuffleOrder[1];
      }
    }
    return null;
  }

  bool get _shuffleHasNext {
    if (_queue.length <= 1) return false;
    _ensureShuffleOrder();
    return _shufflePos + 1 < _shuffleOrder.length ||
        _state.repeatMode == PlayerRepeatMode.all;
  }

  bool get _shuffleHasPrevious {
    if (_queue.isEmpty) return false;
    _ensureShuffleOrder();
    return _shufflePos > 0;
  }

  /// Toggles favorite for whatever is playing. Local files use the
  /// filename flag (Library "Favoritos"); remote Explorer/YouTube items use
  /// the liked-videos store (songs + "Videos que me gustan").
  @override
  Future<void> toggleFavoriteCurrent() async {
    final key = _favoriteKey;
    if (key == null) return;
    if (_isRemoteId(key)) {
      final item = (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : null;
      await MediaMetadataService().toggleLikedVideo(
        url: key,
        title: item?.title ?? _state.title ?? key,
        artist: item?.artist ?? _state.artist,
        thumbnail: item?.artUri?.toString() ?? _state.thumbnail,
        isVideo: _state.mediaType == MediaType.video,
      );
    } else {
      await MediaMetadataService().toggleFavorite(key);
    }
    debugPrint('[MEDIA_SESSION] Favorite toggled for $key');
    notifyListeners();
    // Redraw the card so the heart shows the new state.
    _audioHandler?.refreshControls();
  }

  /// Likes/unlikes an Explorer item WITHOUT changing playback (used by the
  /// detail view heart). Keeps every surface in sync.
  Future<void> toggleRemoteLike({
    required String url,
    required String title,
    String? artist,
    String? thumbnail,
    required bool isVideo,
  }) async {
    await MediaMetadataService().toggleLikedVideo(
      url: url,
      title: title,
      artist: artist,
      thumbnail: thumbnail,
      isVideo: isVideo,
    );
    notifyListeners();
    _audioHandler?.refreshControls();
  }

  bool isRemoteLiked(String url) => MediaMetadataService().isLiked(url);

  /// Favorite state of the current item (drives the card's heart icon).
  @override
  bool get isCurrentFavorite {
    final key = _favoriteKey;
    if (key == null) return false;
    if (_isRemoteId(key)) return MediaMetadataService().isLiked(key);
    return MediaMetadataService().isFavorite(key);
  }

  bool _isRemoteId(String id) =>
      id.startsWith('http://') || id.startsWith('https://');

  /// Favorite key: local files are stored by filename (same key the Library
  /// uses), remote/YouTube items by media id.
  String? get _favoriteKey {
    String? key = _state.mediaId;
    if (key == null) return null;
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      key = _queue[_currentIndex].extras?['filename'] as String? ?? key;
    }
    return key;
  }

  /// Opens the system notification settings for this app (the exact screen
  /// where the user can unblock the media notification).
  Future<void> openNotificationSettings() async {
    try {
      await _mediaDiagChannel.invokeMethod('openNotificationSettings');
    } catch (e) {
      debugPrint('[MEDIA_SESSION] openNotificationSettings failed: $e');
      await openAppSettings();
    }
  }

  // --- Navigation ---

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
    if (_state.isShuffle) {
      final next = _shuffleAdvance();
      if (next == null) return; // end of the shuffled run
      _currentIndex = next;
      await _playCurrentQueueItem();
      return;
    }
    if (_currentIndex < _queue.length - 1) {
      _currentIndex++;
      await _playCurrentQueueItem();
    } else if (_state.repeatMode == PlayerRepeatMode.all) {
      _currentIndex = 0;
      await _playCurrentQueueItem();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;
    if (_state.position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }
    if (_state.isShuffle) {
      _ensureShuffleOrder();
      if (_shufflePos > 0) {
        _shufflePos--;
        _currentIndex = _shuffleOrder[_shufflePos];
        await _playCurrentQueueItem();
      } else {
        await seek(Duration.zero);
      }
      return;
    }
    if (_currentIndex > 0) {
      _currentIndex--;
      await _playCurrentQueueItem();
    } else if (_state.repeatMode == PlayerRepeatMode.all) {
      _currentIndex = _queue.length - 1;
      await _playCurrentQueueItem();
    }
  }

  Future<void> skipToIndex(int index) async {
    if (index < 0 || index >= _queue.length) return;
    _currentIndex = index;
    await _playCurrentQueueItem();
  }

  Future<void> _playCurrentQueueItem() async {
    if (_currentIndex < 0 || _currentIndex >= _queue.length) return;
    _videoQuality = 0; // new item => Auto quality
    final item = _queue[_currentIndex];
    _completionHandled = false;

    final libFile = _resolveLibraryFileFromExtras(item.extras);
    if (libFile != null) {
      await _playLocalFile(libFile);
      return;
    }
    if (item.extras?['isVideo'] == true) {
      // Explorer / liked-video item: full video pipeline (audio fallback
      // included) instead of the audio-only shortcut.
      await _playQueueItemVideo(item,
          startAt: await _resumePositionFor(item.id));
      return;
    }
    final videoId = _parseVideoIdFromUrl(item.id);
    if (videoId != null) {
      final startAt = await _resumePositionFor(item.id);
      await _playYouTubeAudio(item.id, item);
      // Match the video path: restart audio where it stopped instead of 0.
      if (startAt > Duration.zero) await _player.seek(startAt);
    } else {
      final localFile = StorageService.instance.getFile(item.id);
      if (localFile != null && localFile.existsSync()) {
        final isVideo = item.extras?['fileType'] == 'video';
        if (isVideo) {
          await _playVideoFile(localFile, item);
        } else {
          await _playAudioFile(localFile, item);
        }
      } else {
        _state = _state.copyWith(status: MediaStatus.idle);
        _syncPlaybackStateToHandler();
        notifyListeners();
      }
    }
  }

  // --- Public Play Methods ---

  Future<void> playUrl(String url, {String? title, String? artist, String? thumbnail, bool isVideo = false}) async {
    await _stopCurrent();

    final artUri = thumbnail != null ? Uri.tryParse(thumbnail) : null;
    final item = MediaItem(
      id: url,
      title: title ?? 'Unknown',
      artist: artist ?? 'YouTube',
      artUri: artUri,
      extras: <String, dynamic>{'isVideo': isVideo},
    );

    _queue.add(item);
    _currentIndex = _queue.length - 1;
    _completionHandled = false;

    _state = _state.copyWith(
      mediaId: url,
      title: title ?? 'Unknown',
      artist: artist ?? 'YouTube',
      thumbnail: thumbnail,
      mediaType: isVideo ? MediaType.video : MediaType.audio,
      status: MediaStatus.loading,
    );
    _syncToAudioHandler(item);
    _syncQueueToHandler();
    notifyListeners();

    if (isVideo) {
      await _playQueueItemVideo(item,
          startAt: await _resumePositionFor(url));
    } else {
      await _playYouTubeAudio(url, item);
    }
  }

  Future<void> playFile(LibraryFile file) async {
    await _stopCurrent();

    final isYouTube = file.filename.contains('youtube.com') || file.filename.contains('youtu.be');
    if (isYouTube) {
      final item = _libraryFileToMediaItem(file);
      _queue.add(item);
      _currentIndex = _queue.length - 1;
    } else {
      final idx = _queue.indexWhere((i) => i.id == (file.hasContentUri ? file.contentUri : file.filename));
      if (idx != -1) {
        _currentIndex = idx;
      } else {
        final item = _libraryFileToMediaItem(file);
        _queue.add(item);
        _currentIndex = _queue.length - 1;
      }
    }
    _completionHandled = false;
    _syncQueueToHandler();

    await _playLocalFile(file);
  }

  /// Single media-source resolver (Explorer → compatible sources).
  /// Owns the URL cache (with exact expiry), the manifest cache and the
  /// candidate ranking. Engine only iterates and plays.
  late final MediaSourceResolver _resolver = MediaSourceResolver(
    fetchUrls: (videoId) async {
      final urls = await _fetchStreamUrls(videoId);
      if (urls == null) return null;
      return StreamUrlsPayload(
          video: urls.video, audio: urls.audio, proxy: urls.proxy);
    },
    fetchManifest: (videoId) async {
      // Slow networks need patience: the manifest call crosses the ocean
      // and mobile latency regularly exceeds 10s.
      try {
        return await _ytc.videos.streamsClient.getManifest(videoId).timeout(
          const Duration(seconds: 25),
          onTimeout: () => throw TimeoutException('Stream manifest timed out'),
        );
      } catch (_) {
        return null;
      }
    },
  );

  /// Plays a single Explorer result, replacing the queue (Explorer owns its
  /// queue, same as every other screen).
  Future<void> playExploreVideo(ExploreVideo video) {
    return playExploreQueue([video]);
  }

  /// Plays [videos] as a real queue: next/previous, auto-advance at the end
  /// and the notification/lockscreen controls all ride on the shared
  /// MediaEngine queue. [startAt] overrides the saved resume position of the
  /// tapped item (used by the "continue watching" rail).
  Future<void> playExploreQueue(
    List<ExploreVideo> videos, {
    int startIndex = 0,
    Duration? startAt,
  }) async {
    if (videos.isEmpty) return;
    final items = videos.map(_exploreVideoToMediaItem).toList();
    final index = startIndex.clamp(0, items.length - 1);
    final resume = startAt ?? await _resumePositionFor(items[index].id,
        duration: items[index].duration);

    _queue
      ..clear()
      ..addAll(items);
    _currentIndex = index;
    _completionHandled = false;
    playbackError = null;
    _syncQueueToHandler();
    notifyListeners();

    await _playQueueItemVideo(items[index], startAt: resume);
  }

  /// Shared video path for Explorer queue items: state, stall watchdog and
  /// the single MediaSourceResolver chain. Queue auto-advance passes
  /// [startAt] = zero so a fresh item never starts mid-video.
  Future<void> _playQueueItemVideo(MediaItem item,
      {Duration startAt = Duration.zero}) async {
    // Invalidate any resolution chain still running for the previous item,
    // otherwise a slow resolve could hijack this play.
    _playToken++;
    final token = _playToken;
    bool stale() => token != _playToken;

    // Resolve the new stream WHILE the previous player is being torn down.
    // The two are independent and the network round-trip is the slow half, so
    // serializing them (teardown, then resolve) added the teardown to the wait
    // for the first frame. The chain itself still starts only after the
    // teardown, so there is never more than one live player. The stage labels
    // only touch the UI once this item is the current one.
    final videoId = _parseVideoIdFromUrl(item.id);
    final prefetched = videoId == null
        ? null
        : _resolver.resolve(videoId, onStage: (key) {
            if (!stale() && _state.mediaId == item.id) _setStage(key);
          });

    await _stopCurrent();
    _completionHandled = false;
    playbackError = null;
    _videoQuality = 0;

    _state = _state.copyWith(
      mediaId: item.id,
      title: item.title,
      artist: item.artist,
      thumbnail: item.artUri?.toString(),
      mediaType: MediaType.video,
      status: MediaStatus.loading,
      position: Duration.zero,
      duration: Duration.zero,
    );
    _syncToAudioHandler(item);
    _syncQueueToHandler();
    notifyListeners();

    // Stall watchdog: fails the play if nothing moves for 45s. It re-arms
    // itself on every resolution stage (see _setStage), so a progressing
    // chain is never killed.
    _armWatchdog(item.id);

    await _playYouTubeVideo(item.id, item,
        startAt: startAt, prefetched: prefetched);
  }

  /// Saved resume position for a remote URL. Mirrors MediaMetadata.hasResume:
  /// only after 10s watched and only before the last 5% of the video.
  Future<Duration> _resumePositionFor(String mediaId,
      {Duration? duration}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt('$_prefix${mediaId}_pos') ?? 0;
      if (ms < 10000) return Duration.zero;
      final durMs = duration?.inMilliseconds ?? 0;
      if (durMs > 0 && ms / durMs >= 0.95) return Duration.zero;
      return Duration(milliseconds: ms);
    } catch (_) {
      return Duration.zero;
    }
  }

  // --- YouTube Video Playback ---
  //
  // Strategy (backend first) now lives in MediaSourceResolver; the engine
  // only iterates ranked candidates and plays. Cache/TTL/expiry/ranking
  // are the resolver's job.

  /// Current resolution step, shown under the loading spinner.
  /// Holds an ARB key (see playStage*), null when not resolving.
  String? loadingStageKey;

  Duration? _expectedDuration;

  /// Effective position offset for the active network controller. A `?t=`
  /// relay stream may REWRITE timestamps (player clock restarts at 0 → offset
  /// must be added to every read) or PRESERVE them (clock already in real
  /// time → offset must NOT be added). Detected once at start so position,
  /// duration and end-detection stay correct either way.
  Duration _relayClockOffset = Duration.zero;

  /// Last resolved stream URL for the active video: lets the background
  /// handoff (onScreenOff) keep ANY source playing as audio, and lets the
  /// relay seek reconnect from the same endpoint.
  String? _lastDirectUrl;

  /// Kind of the active stream (relay merge needs `?t=` reconnects to seek).
  MediaSourceKind? _activeKind;

  /// Coalescing window for the position-tick notifications (the player
  /// emits ~10/s; see the controller listener in _startNetworkVideo).
  static const _tickNotifyInterval = Duration(milliseconds: 200);
  DateTime _lastTickNotify = DateTime.fromMillisecondsSinceEpoch(0);

  /// True when the controller reports no usable timeline: 0, the ~1ms
  /// wrap of ExoPlayer's C.TIME_UNSET, or absurd values (>24h).
  static bool _durationLooksUnknown(Duration d) =>
      d < const Duration(seconds: 1) || d > const Duration(hours: 24);

  String? _watchdogMedia;

  void _setStage(String? key) {
    if (loadingStageKey == key) return;
    loadingStageKey = key;
    // Forward motion re-arms the stall watchdog (see _armWatchdog).
    if (key != null &&
        _watchdogMedia != null &&
        _state.mediaId == _watchdogMedia) {
      _armWatchdog(_watchdogMedia!);
    }
    notifyListeners();
  }

  void _clearStage() {
    loadingStageKey = null;
    _playWatchdog?.cancel();
    _watchdogMedia = null;
  }

  /// Fails the play if the status is still loading/buffering 45s after the
  /// last forward-motion signal. Re-armed on every stage change, so a slow
  /// but progressing chain is never killed, while a wedged one can't spin
  /// forever.
  void _armWatchdog(String mediaId) {
    _playWatchdog?.cancel();
    _watchdogMedia = mediaId;
    final stage = loadingStageKey;
    _playWatchdog = Timer(const Duration(seconds: 45), () {
      final s = _state;
      if (s.mediaId == mediaId &&
          (s.status == MediaStatus.loading ||
              s.status == MediaStatus.buffering) &&
          loadingStageKey == stage) {
        debugPrint('[MediaEngine] Play watchdog fired for $mediaId');
        playbackError ??= 'timeout';
        _clearStage();
        _state = s.copyWith(status: MediaStatus.idle);
        _syncPlaybackStateToHandler();
        notifyListeners();
      }
    });
  }

  /// Re-arms the stall watchdog with the CURRENT stage. The candidate chain
  /// (relay → direct → …) walks through several sources, each with its own
  /// stage: without this re-arm the original 45s timer would kill a healthy
  /// chain while it was still working on the next candidate.
  void _rearmWatchdog() {
    final id = _watchdogMedia ?? _state.mediaId;
    if (id != null && id.isNotEmpty) _armWatchdog(id);
  }

  /// Rewrites a stream URL to start at [at] seconds. The relay merge has no
  /// index, so seeking / resuming / backgrounding it means reconnecting the
  /// server-side ffmpeg with `-ss at` (via the `t` query parameter).
  static Uri _relayUriWithStart(Uri uri, Duration at) {
    final params = Map<String, String>.from(uri.queryParameters);
    params['t'] = at.inSeconds.toString();
    return uri.replace(queryParameters: params);
  }

  /// Monotonic play generation: rapid taps (A then B) abandon the stale
  /// resolution chain instead of letting it hijack the new playback.
  int _playToken = 0;

  Future<void> _playYouTubeVideo(String youtubeUrl, MediaItem mediaItem,
      {Duration startAt = Duration.zero,
      Future<MediaResolution>? prefetched}) async {
    final videoId = _parseVideoIdFromUrl(youtubeUrl);
    if (videoId == null) {
      final uri = Uri.tryParse(youtubeUrl);
      if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
        // Any other site (TikTok, Instagram, Facebook...): resolve a fresh
        // direct media URL through the backend and play it in this same
        // pipeline instead of failing with "invalid URL".
        await _playExternalVideo(youtubeUrl, mediaItem, startAt: startAt);
        return;
      }
      debugPrint('[MediaEngine] Invalid URL: $youtubeUrl');
      _clearStage();
      _failPlayback('URL inválida');
      return;
    }
    final token = _playToken;
    bool stale() => token != _playToken;

    final errs = <String>[];
    late final MediaResolution res;
    try {
      res = prefetched != null
          ? await prefetched
          : await _resolver.resolve(
              videoId,
              // A stage from an abandoned chain must not re-label (or re-arm
              // the watchdog of) the play the user is waiting on now.
              onStage: (key) {
                if (!stale()) _setStage(key);
              },
            );
    } catch (e) {
      debugPrint('[MediaEngine] Resolve failed: $e');
      // Failing here would cancel the LIVE chain's watchdog and paint the
      // current item with this abandoned chain's error.
      if (stale()) return;
      _clearStage();
      _failPlayback(_short(e.toString()));
      return;
    }
    if (stale()) return;
    if (res.fetchError != null) {
      errs.add('servidor: ${_lastStreamError ?? "sin url"}');
    }

    for (final c in res.video) {
      if (stale()) return;
      // Each candidate gets a fresh 45s budget: the whole chain (resolve +
      // direct + proxy + relay) can legitimately take longer than a single
      // watchdog window, and a re-armed timer never kills a live attempt.
      _rearmWatchdog();
      // The relay merge has no in-stream index, so starting mid-video must
      // go through `?t=` (ffmpeg -ss on the server) instead of seekTo.
      final needsT =
          c.kind == MediaSourceKind.relayMerge && startAt > Duration.zero;
      final uri = needsT ? _relayUriWithStart(c.uri, startAt) : c.uri;
      final started = await _tryStartNetworkVideo(
          uri, youtubeUrl, mediaItem,
          initTimeout: c.initTimeout,
          playToken: token,
          startAt: startAt,
          kind: c.kind);
      if (stale()) return;
      if (started) {
        _clearStage();
        return;
      }
      errs.add('${c.errTag}: ${_lastVideoError ?? "init falló"}');
    }

    if (res.audioUri != null) {
      _setStage('playStageAudio');
      if (stale()) return;
      final ok = await _playYouTubeAudio(youtubeUrl, mediaItem,
          streamUri: res.audioUri);
      if (ok) {
        _clearStage();
        return;
      }
      errs.add('audio: ${_lastAudioError ?? "falló"}');
    }

    // Last resort: the manifest is no longer on the critical path, so it
    // may still be in flight. Only a chain that already failed every video
    // and audio-URL candidate reaches here, so waiting costs nothing.
    final manifest = res.manifest ?? await res.manifestAsync;
    if (stale()) return;
    if (manifest != null) {
      _setStage('playStageAudio');
      final ok =
          await _playYouTubeAudio(youtubeUrl, mediaItem, manifest: manifest);
      if (ok) {
        _clearStage();
        return;
      }
      errs.add('audio directo: ${_lastAudioError ?? "falló"}');
    }

    if (stale()) return;
    _clearStage();
    final detail = errs.join(' · ');
    _failPlayback(detail.isEmpty
        ? 'no reproducible'
        : detail.length > 280 ? '${detail.substring(0, 280)}…' : detail);
  }

  /// Non-YouTube links (TikTok, Instagram, Facebook, ...): ask the backend
  /// analyze endpoint for a fresh direct media URL and play it through the
  /// same video pipeline (_tryStartNetworkVideo) as YouTube, so every link
  /// pasted/shared into VibeGrab plays in OUR player.
  Future<void> _playExternalVideo(String url, MediaItem mediaItem,
      {Duration startAt = Duration.zero}) async {
    final token = _playToken;
    bool stale() => token != _playToken;
    _setStage('playStageServer');
    try {
      // 40s < the 45s stall watchdog armed by _setStage above, so a hung
      // server surfaces as an error instead of a watchdog kill race.
      final response = await http
          .post(
            Uri.parse(ApiConfig.analyzeUrl),
            headers: {
              'Content-Type': 'application/json',
              ...ApiConfig.authHeaders,
            },
            body: jsonEncode({'url': url}),
          )
          .timeout(const Duration(seconds: 40));
      if (stale()) return;

      String? direct;
      Duration? extDuration;
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        // Real duration from the extractor: without it external videos
        // would run with an unknown timeline (00:00, no seeks).
        final media = body['media'];
        if (media is Map && media['duration'] is num) {
          final secs = (media['duration'] as num).toInt();
          if (secs > 0) extDuration = Duration(seconds: secs);
        }
        String? progressive720;
        String? progressiveAny;
        String? videoOnly;
        String? audio;
        for (final f in (body['formats'] as List? ?? const [])) {
          if (f is! Map<String, dynamic>) continue;
          final u = f['direct_url'] as String?;
          if (u == null || u.isEmpty) continue;
          final isVideo = f['type'] == 'video';
          final hasAudio = f['has_audio'] == true;
          if (isVideo && hasAudio) {
            // Backend lists combined videos best-height first: keep the
            // first ≤720p (data-friendly) and the overall best as backup.
            progressiveAny ??= u;
            final h = int.tryParse(
                    (f['quality'] as String? ?? '').replaceAll('p', '')) ??
                0;
            if (h == 0 || h <= 720) progressive720 ??= u;
          } else if (isVideo) {
            videoOnly ??= u;
          } else {
            audio ??= u;
          }
        }
        direct = progressive720 ?? progressiveAny ?? videoOnly ?? audio;
      }

      if (direct == null) {
        debugPrint(
            '[MediaEngine] external resolve failed: http ${response.statusCode}');
        _clearStage();
        _failPlayback(response.statusCode == 200
            ? 'no reproducible'
            : 'servidor: http ${response.statusCode}');
        return;
      }

      final started = await _tryStartNetworkVideo(
        Uri.parse(direct),
        url,
        mediaItem,
        initTimeout: const Duration(seconds: 20),
        playToken: token,
        startAt: startAt,
        expectedDuration: extDuration,
      );
      if (stale()) return;
      _clearStage();
      if (started) return;
      _failPlayback(_lastVideoError ?? 'no reproducible');
    } catch (e) {
      if (stale()) return;
      debugPrint('[MediaEngine] external play failed: $e');
      _clearStage();
      _failPlayback(_short(e.toString()));
    }
  }

  /// Current video quality height, 0 = Auto.
  int _videoQuality = 0;
  int get videoQuality => _videoQuality;

  /// Real qualities known for the current video (empty = Auto only).
  List<MediaQuality> get videoQualities {
    final id = _state.mediaId;
    if (id == null || !isVideo) return const [];
    final videoId = _parseVideoIdFromUrl(id);
    if (videoId == null) return const [];
    return _resolver.qualitiesFor(videoId);
  }

  /// Switches video quality preserving the position when possible.
  /// height == 0 means Auto (default resolution chain).
  Future<void> switchVideoQuality(int height) async {
    final mediaId = _state.mediaId;
    if (mediaId == null || _videoController == null) return;
    final videoId = _parseVideoIdFromUrl(mediaId);
    if (videoId == null) return;
    final savedPos =
        _state.position > const Duration(seconds: 1) ? _state.position : Duration.zero;
    final token = ++_playToken;
    bool ok = false;
    if (height > 0) {
      final uri = _resolver.muxedUrlFor(videoId, height);
      if (uri != null) {
        ok = await _tryStartNetworkVideo(uri, mediaId,
            _createMediaItemFromState(),
            initTimeout: const Duration(seconds: 12), playToken: token);
        if (ok) _videoQuality = height;
      }
    } else {
      final item = (_currentIndex >= 0 && _currentIndex < _queue.length)
          ? _queue[_currentIndex]
          : _createMediaItemFromState();
      await _playYouTubeVideo(mediaId, item);
      ok = _state.isPlaying && _state.mediaId == mediaId;
      if (ok) _videoQuality = 0;
    }
    if (token != _playToken) return;
    if (ok && savedPos > Duration.zero) {
      await seek(savedPos);
    }
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  static String _short(String s) => s.length > 70 ? s.substring(0, 70) : s;

  Future<bool> _tryStartNetworkVideo(
      Uri streamUrl, String youtubeUrl, MediaItem mediaItem,
      {Duration initTimeout = const Duration(seconds: 15),
      int? playToken,
      Duration startAt = Duration.zero,
      Duration? expectedDuration,
      MediaSourceKind? kind}) async {
    // A newer play already owns the engine. Tearing down here would dispose
    // (and null) the controller the NEW chain just installed, killing a
    // perfectly good play from a chain the user already abandoned.
    if (playToken != null && playToken != _playToken) return false;
    await _stopCurrentSilent();
    // The relay merge streams without a declared length (unknown duration).
    // Keep the metadata (or analyze-provided) duration as the expected one
    // so progress, total time, seeks and end-of-track detection keep working.
    _expectedDuration = expectedDuration ?? mediaItem.duration;
    // Remember what is playing: background fallback + relay-seek reconnect.
    _lastDirectUrl = streamUrl.toString();
    _activeKind = kind;
    _state = _state.copyWith(
      mediaId: youtubeUrl,
      title: mediaItem.title,
      artist: mediaItem.artist ?? 'YouTube',
      thumbnail: mediaItem.artUri?.toString(),
      mediaType: MediaType.video,
      status: MediaStatus.buffering,
      duration: _expectedDuration ?? Duration.zero,
    );
    _syncToAudioHandler(mediaItem);
    notifyListeners();

    final started = await _startNetworkVideo(streamUrl, youtubeUrl,
        startAt: startAt, initTimeout: initTimeout, playToken: playToken);
    if (!started) return false;
    playbackError = null;

    MediaMetadataService().recordPlay(
      filename: youtubeUrl,
      title: mediaItem.title,
      thumbnail: mediaItem.artUri?.toString(),
      fileType: 'video',
      source: mediaItem.artist,
    );
    return true;
  }

  void _failPlayback(String reason) {
    playbackError = reason;
    _state = _state.copyWith(status: MediaStatus.idle);
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  /// In-flight stream-URL requests by videoId.
  ///
  /// The detail view asks for the metadata that the SAME response carries
  /// (channel avatar, comment count, description) at the very moment the
  /// playback resolve asks for the stream URLs. Without single-flight the
  /// app issued two parallel requests to /api/explore/stream-url for the
  /// same video against a backend that may still be waking up (~40s).
  final Map<String, Future<StreamUrls?>> _streamUrlFutures = {};

  /// Server metadata for [videoId], sharing the single in-flight request
  /// with the playback resolve of the same video.
  Future<StreamUrls?> fetchMeta(String videoId) =>
      _fetchStreamUrls(videoId);

  Future<StreamUrls?> _fetchStreamUrls(String videoId) => _streamUrlFutures
      .putIfAbsent(videoId, () => _fetchStreamUrlsOnce(videoId));

  Future<StreamUrls?> _fetchStreamUrlsOnce(String videoId) async {
    try {
      return await _fetchStreamUrlsBody(videoId);
    } finally {
      _streamUrlFutures.remove(videoId);
    }
  }

  Future<StreamUrls?> _fetchStreamUrlsBody(String videoId) async {
    _lastStreamError = null;
    // Slow networks need patience, not more routes: one generous attempt
    // plus a single backoff retry (covers a waking backend). Short
    // timeouts on high-latency carriers always die halfway.
    const delays = [Duration(seconds: 5)];
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await http
            .get(
              Uri.parse('${ApiConfig.exploreStreamUrl}?v=$videoId'),
              headers: ApiConfig.authHeaders,
            )
            .timeout(const Duration(seconds: 25));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          if (data['success'] != false) {
            return StreamUrls.fromJson(data);
          }
          debugPrint('[MediaEngine] stream-url error: ${data['detail']}');
          _lastStreamError = _short('${data['detail'] ?? 'error'}');
        } else {
          _lastStreamError = 'http ${response.statusCode}';
        }
      } catch (e) {
        debugPrint('[MediaEngine] stream-url fallback failed: $e');
        _lastStreamError = _short(e.toString());
      }
      if (attempt < delays.length) {
        await Future.delayed(delays[attempt]);
      }
    }
    return null;
  }

  MuxedStreamInfo? _bestMuxedStream(StreamManifest manifest) {
    final muxed = manifest.muxed.toList();
    if (muxed.isEmpty) return null;
    muxed.sort((a, b) {
      final heightDiff =
          b.videoResolution.height.compareTo(a.videoResolution.height);
      if (heightDiff != 0) return heightDiff;
      return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
    });
    final upTo480 = muxed.where((s) => s.videoResolution.height <= 480).toList();
    if (upTo480.isNotEmpty) return upTo480.first;
    final upTo720 = muxed.where((s) => s.videoResolution.height <= 720).toList();
    if (upTo720.isNotEmpty) return upTo720.first;
    return muxed.last;
  }

  Future<bool> _startNetworkVideo(
    Uri streamUrl,
    String mediaId, {
    Duration startAt = Duration.zero,
    Duration initTimeout = const Duration(seconds: 15),
    int? playToken,
  }) async {
    _lastVideoError = null;
    await _videoController?.dispose();
    final controller = VideoPlayerController.networkUrl(
      streamUrl,
      httpHeaders: ApiConfig.streamHeaders,
    );
    _videoController = controller;

    try {
      await controller.initialize().timeout(
        initTimeout,
        onTimeout: () => throw TimeoutException('Video initialization timed out'),
      );
    } catch (e) {
      debugPrint('[MediaEngine] Network video init error: $e');
      _lastVideoError = _short(e.toString());
      await controller.dispose();
      if (identical(_videoController, controller)) _videoController = null;
      return false;
    }

    try {
      if (controller.value.hasError) {
        debugPrint(
            '[MediaEngine] Network video error: ${controller.value.errorDescription}');
        _lastVideoError =
            controller.value.errorDescription ?? 'video error';
        await controller.dispose();
        if (identical(_videoController, controller)) _videoController = null;
        return false;
      }

      // Merge/proxy streams without a declared length make ExoPlayer report
      // C.TIME_UNSET (wraps to ~1ms). The plugin then clamps position AND
      // every seekTo against that ~0 duration: bar frozen at 00:00 and all
      // forward seeks collapsing to 0. Inject the expected duration so the
      // clamps, the UI and seeks all work.
      if (_durationLooksUnknown(controller.value.duration) &&
          _expectedDuration != null) {
        controller.value = controller.value.copyWith(duration: _expectedDuration);
      }

      // Streams started from a `?t=` relay URL already begin at startAt —
      // seeking again on an index-less merge jumps back to 0. But the relay
      // may either REWRITE timestamps (player clock restarts at 0 and reports
      // the REMAINING length) or PRESERVE them (clock and length stay in real
      // time). Blindly adding `t` on every read doubles the offset against a
      // preserving stream — the exact "wrong time" glitch. Detect the mode by
      // comparing the reported length with the known metadata length.
      final tParam = int.tryParse(streamUrl.queryParameters['t'] ?? '');
      var posOffset = (tParam != null && tParam > 0)
          ? Duration(seconds: tParam)
          : Duration.zero;
      if (posOffset > Duration.zero &&
          !_durationLooksUnknown(controller.value.duration)) {
        final meta0 = _expectedDuration;
        if (meta0 != null && meta0 > Duration.zero) {
          final raw0 = controller.value.duration;
          final looksRemaining =
              (raw0 + posOffset - meta0).abs() <= const Duration(seconds: 3);
          final looksPreserved =
              (raw0 - meta0).abs() <= const Duration(seconds: 3);
          if (looksPreserved && !looksRemaining) {
            posOffset = Duration.zero;
          }
        }
      }
      _relayClockOffset = posOffset;
      if (startAt > Duration.zero && posOffset == Duration.zero) {
        await controller.seekTo(startAt);
      }

      _lastTickNotify = DateTime.fromMillisecondsSinceEpoch(0);
      controller.addListener(() {
        if (!identical(_videoController, controller)) return;
        if (!controller.value.isInitialized) return;
        if (controller.value.hasError) return;
        final meta = _expectedDuration;
        final pos = controller.value.position + _relayClockOffset;
        final rawDur = controller.value.duration;
        // The metadata length is authoritative when we have it: the relay's
        // own timeline (remaining- or total-based) is only a fallback, and a
        // wrong total skews the bar, every seek target and end detection.
        Duration dur;
        if (meta != null && meta > Duration.zero) {
          dur = meta;
          if (_durationLooksUnknown(rawDur)) {
            // Re-inject: the plugin's seek/position clamps read value.duration.
            controller.value = controller.value.copyWith(duration: meta);
          }
        } else if (_durationLooksUnknown(rawDur)) {
          dur = Duration.zero;
        } else if (_relayClockOffset > Duration.zero) {
          dur = rawDur + _relayClockOffset;
        } else {
          dur = rawDur;
        }
        final clampedPos = (dur > Duration.zero && pos > dur) ? dur : pos;
        _state = _state.copyWith(position: clampedPos, duration: dur);
        _savePosition(mediaId, clampedPos);
        _syncPlaybackStateToHandler();

        if (!_completionHandled &&
            dur > Duration.zero &&
            clampedPos >= dur &&
            !controller.value.isPlaying) {
          _completionHandled = true;
          _handlePlaybackComplete();
          notifyListeners();
          return;
        }
        // Coalesce the rebuilds: the player ticks ~10/s and each tick used
        // to rebuild every Consumer<MediaEngine> in the app (mini player,
        // Shorts pages, detail player) for a progress bar that moves a few
        // pixels. 200ms is several times smoother than that needs.
        final now = DateTime.now();
        if (now.difference(_lastTickNotify) < _tickNotifyInterval) return;
        _lastTickNotify = now;
        notifyListeners();
      });

      final rawInit = controller.value.duration;
      final expDur = _expectedDuration;
      final initDur = (expDur != null && expDur > Duration.zero)
          ? expDur
          : (posOffset > Duration.zero && !_durationLooksUnknown(rawInit)
              ? rawInit + posOffset
              : rawInit);
      // A newer play started while we initialized: abandon instead of
      // hijacking it. The check has to come BEFORE the state write —
      // writing first let a stale chain paint the live item's state, hide
      // its spinner and disarm its stall watchdog before bailing out.
      if (playToken != null && playToken != _playToken) {
        await controller.dispose();
        if (identical(_videoController, controller)) _videoController = null;
        return false;
      }
      _state = _state.copyWith(
        status: MediaStatus.playing,
        position: posOffset > Duration.zero ? posOffset : startAt,
        // Never inherit the previous item's duration: it would show a
        // wrong total until the first listener tick.
        duration: _durationLooksUnknown(initDur)
            ? (expDur ?? Duration.zero)
            : initDur,
      );
      _syncPlaybackStateToHandler();
      notifyListeners();
      await controller.play();
      // Keep the freshest stream URL for the background handoff and relay
      // seeks (a reconnect writes its own `?t=` variant here).
      _lastDirectUrl = streamUrl.toString();
      // Resolve the audio-only URL NOW, while the app is on screen. Doing it
      // at screen-off time means a network wait inside a backgrounded app,
      // which is exactly when the OS is free to freeze the isolate.
      unawaited(_warmBackgroundAudio(mediaId));
      return true;
    } catch (e) {
      debugPrint('[MediaEngine] Network video start error: $e');
      _lastVideoError = _short(e.toString());
      await controller.dispose();
      if (identical(_videoController, controller)) _videoController = null;
      return false;
    }
  }

  // --- YouTube Audio Playback ---

  Future<bool> _playYouTubeAudio(String youtubeUrl, MediaItem mediaItem,
      {StreamManifest? manifest, Uri? streamUri}) async {
    try {
      Uri streamUrl;
      if (streamUri != null) {
        streamUrl = streamUri;
      } else {
        final videoId = _parseVideoIdFromUrl(youtubeUrl);
        if (videoId == null) {
          debugPrint('[MediaEngine] Invalid YouTube URL: $youtubeUrl');
          return false;
        }

        final resolved = manifest ??
            await _ytc.videos.streamsClient.getManifest(videoId)
                .timeout(const Duration(seconds: 10), onTimeout: () {
              throw TimeoutException('Stream manifest timed out');
            });

        final audioStreams = resolved.audioOnly.toList()
          ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

        if (audioStreams.isEmpty) {
          debugPrint('[MediaEngine] No audio streams found for $youtubeUrl');
          return false;
        }
        streamUrl = audioStreams.first.url;
      }

      await _stopCurrentSilent();
      _state = _state.copyWith(
        mediaId: youtubeUrl,
        title: mediaItem.title,
        artist: mediaItem.artist ?? 'YouTube',
        thumbnail: mediaItem.artUri?.toString(),
        mediaType: MediaType.audio,
        status: MediaStatus.buffering,
      );
      _syncToAudioHandler(mediaItem);
      notifyListeners();

      await _player
          .setAudioSource(AudioSource.uri(
            streamUrl,
            tag: mediaItem,
            headers: ApiConfig.streamHeaders,
          ))
          .timeout(const Duration(seconds: 20));
      _wireAudioSubscriptions(youtubeUrl);

      playbackError = null;
      _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
      _syncPlaybackStateToHandler();
      notifyListeners();
      // just_audio's play() completes when playback ENDS. Awaiting it made
      // every following line (history, state, handler sync) run only when the
      // track stopped.
      unawaited(_player.play());

      MediaMetadataService().recordPlay(
        filename: youtubeUrl,
        title: mediaItem.title,
        thumbnail: mediaItem.artUri?.toString(),
        fileType: 'audio',
        source: mediaItem.artist,
      );
      return true;
    } catch (e) {
      debugPrint('[MediaEngine] YouTube audio play error: $e');
      _lastAudioError = _short(e.toString());
      return false;
    }
  }

  // --- Local File Playback ---

  Future<void> _playLocalFile(LibraryFile file) async {
    // Local playback: forget the previous network stream, otherwise a later
    // seek would try to reconnect the old relay instead of seeking the file.
    _activeKind = null;
    _lastDirectUrl = null;
    debugPrint('[MediaEngine] _playLocalFile: ${file.title}, type=${file.fileType}, hasContentUri=${file.hasContentUri}');
    final mediaId = file.hasContentUri ? file.contentUri! : file.filename;
    final video = file.isVideo;

    // A downloaded file carries its own title/artist/album and cover when it
    // was encoded by the backend. Reading them here keeps the player and the
    // media session honest even when the download has no `.meta.json` sidecar
    // or the saved thumbnail went missing. The `.meta.json` values stay as the
    // fallback.
    var tags = const AudioTags();
    File? embeddedCover;
    if (!video && file.filePath.isNotEmpty) {
      final source = File(file.filePath);
      if (source.existsSync()) {
        tags = Id3Reader.read(source);
        embeddedCover = await _writeCoverToCache(source, tags);
      }
    }

    final artUri = embeddedCover != null
        ? Uri.file(embeddedCover.path)
        : _resolveArtUri(file);
    final thumbnailPath = embeddedCover?.path ?? file.thumbnailPath;
    final displayTitle = tags.title ?? file.title;
    final displayArtist = tags.artist ?? file.source ?? 'VibeGrab';
    final mediaItem = MediaItem(
      id: mediaId,
      title: displayTitle,
      artist: displayArtist,
      album: tags.album ?? file.album,
      artUri: artUri,
      duration: file.durationMs != null ? Duration(milliseconds: file.durationMs!) : null,
      extras: {
        'fileType': file.fileType,
        'filePath': file.filePath,
        'filename': file.filename,
        'libraryFile': jsonEncode(file.toJson()),
      },
    );

    _state = _state.copyWith(
      mediaId: mediaId,
      title: displayTitle,
      artist: displayArtist,
      thumbnail: file.thumbnail,
      thumbnailPath: thumbnailPath,
      mediaType: video ? MediaType.video : MediaType.audio,
      status: MediaStatus.loading,
    );
    _syncToAudioHandler(mediaItem);
    notifyListeners();

    MediaMetadataService().recordPlay(
      filename: file.filename,
      title: displayTitle,
      thumbnail: file.thumbnail,
      fileType: file.isVideo ? 'video' : 'audio',
      source: file.source,
    );

    if (video) {
      await _playVideoLocal(file, mediaId);
    } else {
      final uri = _resolvePlaybackUri(file);
      if (uri == null) {
        _state = _state.copyWith(status: MediaStatus.idle);
        _syncPlaybackStateToHandler();
        notifyListeners();
        return;
      }

      try {
        await _player.setAudioSource(AudioSource.uri(uri, tag: mediaItem));
      } catch (e) {
        debugPrint('[MediaEngine] Audio source error: $e');
        _state = _state.copyWith(status: MediaStatus.idle);
        _syncPlaybackStateToHandler();
        notifyListeners();
        return;
      }

      await _loadPosition(mediaId);
      if (_state.position.inSeconds > 0) {
        await _player.seek(_state.position);
      }

      _wireAudioSubscriptions(mediaId);

      _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
      _syncPlaybackStateToHandler();
      notifyListeners();
      debugPrint('[MediaEngine] Calling _player.play() for: ${file.title}');
      unawaited(_player.play());
    }
  }

  Future<void> _playAudioFile(File file, MediaItem item) async {
    try {
      await _player.setAudioSource(AudioSource.uri(Uri.file(file.path), tag: item));
    } catch (e) {
      debugPrint('[MediaEngine] Audio source error: $e');
      _state = _state.copyWith(status: MediaStatus.idle);
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    _wireAudioSubscriptions(item.id);

    _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
    _syncPlaybackStateToHandler();
    notifyListeners();
    unawaited(_player.play());
  }

  Future<void> _playVideoFile(File file, MediaItem item) async {
    // Local playback: forget the previous network stream (stale relay seek).
    _activeKind = null;
    _lastDirectUrl = null;
    await _videoController?.dispose();
    _videoController = VideoPlayerController.file(file);

    try {
      await _videoController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Video initialization timed out'),
      );
    } catch (e) {
      debugPrint('[MediaEngine] Video init error: $e');
      _state = _state.copyWith(status: MediaStatus.idle);
      await _videoController?.dispose();
      _videoController = null;
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    if (_videoController!.value.hasError) {
      debugPrint('[MediaEngine] Video has error: ${_videoController!.value.errorDescription}');
      _state = _state.copyWith(status: MediaStatus.idle);
      await _videoController?.dispose();
      _videoController = null;
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    _videoController!.addListener(() {
      if (_videoController == null || !_videoController!.value.isInitialized) return;
      if (_videoController!.value.hasError) return;
      final pos = _videoController!.value.position;
      final dur = _videoController!.value.duration;
      _state = _state.copyWith(position: pos, duration: dur);
      _savePosition(item.id, pos);
      _syncPlaybackStateToHandler();

      if (!_completionHandled && pos >= dur && dur > Duration.zero) {
        _completionHandled = true;
        _handlePlaybackComplete();
      }
      notifyListeners();
    });

    _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
    _syncPlaybackStateToHandler();
    notifyListeners();
    await _videoController!.play();
  }

  Future<void> _playVideoLocal(LibraryFile file, String mediaId) async {
    // Local playback: forget the previous network stream (stale relay seek).
    _activeKind = null;
    _lastDirectUrl = null;
    final uri = _resolvePlaybackUri(file);
    if (uri == null) {
      _state = _state.copyWith(status: MediaStatus.idle);
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    await _videoController?.dispose();
    if (file.hasContentUri) {
      _videoController = VideoPlayerController.contentUri(uri);
    } else if (uri.scheme == 'file') {
      _videoController = VideoPlayerController.file(File(uri.toFilePath()));
    } else {
      _videoController = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: ApiConfig.streamHeaders,
      );
    }

    try {
      await _videoController!.initialize().timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException('Video initialization timed out'),
      );
    } catch (e) {
      debugPrint('[MediaEngine] Video init error: $e');
      _state = _state.copyWith(status: MediaStatus.idle);
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    if (_videoController!.value.hasError) {
      debugPrint('[MediaEngine] Video has error: ${_videoController!.value.errorDescription}');
      _state = _state.copyWith(status: MediaStatus.idle);
      await _videoController?.dispose();
      _videoController = null;
      _syncPlaybackStateToHandler();
      notifyListeners();
      return;
    }

    await _loadPosition(mediaId);
    if (_state.position.inSeconds > 0) {
      await _videoController!.seekTo(_state.position);
    }

    _videoController!.addListener(() {
      if (_videoController == null || !_videoController!.value.isInitialized) return;
      if (_videoController!.value.hasError) return;
      final pos = _videoController!.value.position;
      final dur = _videoController!.value.duration;
      _state = _state.copyWith(position: pos, duration: dur);
      _savePosition(mediaId, pos);
      _syncPlaybackStateToHandler();

      if (!_completionHandled && pos >= dur && dur > Duration.zero) {
        _completionHandled = true;
        _handlePlaybackComplete();
      }
      notifyListeners();
    });

    _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
    _syncPlaybackStateToHandler();
    notifyListeners();
    await _videoController!.play();
  }

  // --- Screen Off / Audio Background ---

  Future<void> onScreenOff() async {
    if (isInPiP) return;
    if (!isVideo || _videoController == null) return;
    if (!_state.isPlaying) return;

    final mediaId = _state.mediaId;
    if (mediaId == null) return;

    // Logical position/duration: the video controller's clock restarts at 0
    // on relay `?t=` streams, so the offset-aware state is the truth here.
    final savedPosition = _state.position;
    final savedDuration = _state.duration;
    final videoBefore = _videoController;

    _appInBackground = true;

    // Resolve/buffer the audio WITHOUT touching the video. The source is
    // usually already warm (resolved while the video was still playing), so
    // this costs no network at all now that the screen is off.
    AudioSource? source;
    if (_warmAudioMediaId == mediaId && _warmAudioSource != null) {
      source = _warmAudioSource;
      _bgAudioOffset = Duration.zero;
    } else {
      source = await _prepareBackgroundAudio(mediaId, savedPosition);
    }
    if (source == null) {
      _bgAudioOffset = Duration.zero;
      debugPrint('[MediaEngine] No background audio source for $mediaId');
      return;
    }

    try {
      // Loading does not play: the audio player is idle during video
      // playback, so this cannot double the sound.
      await _player.setAudioSource(source);
    } catch (e) {
      debugPrint('[MediaEngine] Screen off audio load error: $e');
      _bgAudioOffset = Duration.zero;
      return;
    }

    // Resolving took time. The app must still be in the background and the
    // same item must still be playing; otherwise taking over would hijack
    // whatever the user is watching now.
    if (!_appInBackground ||
        _state.mediaId != mediaId ||
        !identical(_videoController, videoBefore) ||
        _state.status == MediaStatus.paused) {
      _bgAudioOffset = Duration.zero;
      return;
    }
    final logicalNow = _state.position;
    final audioStart = logicalNow > _bgAudioOffset
        ? logicalNow - _bgAudioOffset
        : Duration.zero;

    // Swap with NO silence: pause the video (momentarily), start the audio,
    // and only release the video once the audio is actually the active
    // player. The old order disposed the video BEFORE play() and then awaited
    // the play future — which completes when playback ENDS — so the handler
    // sync, the position listeners and `_isAudioBackgroundActive` never ran:
    // silent playback, frozen UI, and Play restored nothing.
    try {
      await _videoController?.pause();
      await _player.seek(audioStart);
      unawaited(_player.play());
    } catch (e) {
      debugPrint('[MediaEngine] Screen off audio play error: $e');
      _bgAudioOffset = Duration.zero;
      try {
        await _videoController?.play();
      } catch (_) {}
      return;
    }

    if (!_appInBackground) {
      // The user came back before the swap finished: drop the audio and keep
      // the video that is still on screen.
      try {
        await _player.pause();
        await _videoController?.play();
      } catch (_) {}
      _bgAudioOffset = Duration.zero;
      return;
    }
    if (!_player.playing) {
      // The source refused to play (expired URL, unsupported codec): never
      // report playback that is not happening.
      debugPrint('[MediaEngine] Screen off: audio did not start, keeping video');
      _bgAudioOffset = Duration.zero;
      try {
        await _videoController?.play();
      } catch (_) {}
      return;
    }

    _completionDebounce?.cancel();
    _wireAudioSubscriptions(mediaId);
    // Release the video only now: the sound is already coming from the audio
    // player, so disposing cannot open an audible gap.
    await _videoController?.dispose();
    _videoController = null;

    _state = _state.copyWith(
      status: MediaStatus.playing,
      position: logicalNow,
      duration: savedDuration,
    );
    _isAudioBackgroundActive = true;
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  Future<void> onScreenOn() async {
    _appInBackground = false;
    if (!_isAudioBackgroundActive) return;

    // Logical position: the audio clock excludes the relay `t` offset.
    final savedPosition = _state.position;
    final mediaId = _state.mediaId;

    if (mediaId == null) {
      await _stopBackgroundAudio();
      return;
    }

    final localFile = StorageService.instance.getFile(mediaId);
    if (localFile != null && localFile.existsSync()) {
      if (_state.mediaId != mediaId) {
        // The queue moved on while the screen was off.
        return;
      }
      // A local file initializes in milliseconds: bring the video up FIRST
      // and only then silence the audio, so the swap cannot be heard.
      final restored = await _restoreLocalVideo(localFile, savedPosition);
      if (!restored || !_isAudioBackgroundActive) return;
      await _stopBackgroundAudio();
      return;
    }

    // Network video: the restore costs seconds of network init. The audio
    // keeps PLAYING through it (it used to be paused up front, which is the
    // freeze heard when the app comes back) and is only stopped once the
    // video is live.
    final restored = await _restoreNetworkVideo(savedPosition);
    if (!_isAudioBackgroundActive) return; // another play took over meanwhile
    if (restored) {
      await _catchVideoUpToAudio();
      await _stopBackgroundAudio();
    } else {
      debugPrint(
          '[MediaEngine] Screen on: video restore failed, audio keeps going');
    }
  }

  /// Silences the background audio player once the video took over (or when
  /// there is nothing left to play). Cancels the listeners FIRST: a last
  /// event must not persist an offset-less position over the real one.
  Future<void> _stopBackgroundAudio() async {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    try {
      await _player.stop();
    } catch (_) {}
    _bgAudioOffset = Duration.zero;
    _isAudioBackgroundActive = false;
  }

  /// The video came back while the background audio kept playing, so the
  /// audio is ahead of the position the restore started from. Pull the
  /// video forward by that gap instead of rewinding the content the moment
  /// the audio is stopped. Skipped on relay-merge streams, where an
  /// in-player seek does nothing and a reconnect would re-resolve the URL.
  Future<void> _catchVideoUpToAudio() async {
    final c = _videoController;
    if (c == null || !c.value.isInitialized) return;
    final logicalNow = _player.position + _bgAudioOffset;
    if (logicalNow - _state.position < const Duration(seconds: 2)) return;
    if (_activeKind == MediaSourceKind.relayMerge) return;
    final physical = logicalNow - _relayClockOffset;
    if (physical < Duration.zero) return;
    try {
      await c.seekTo(physical);
      _state = _state.copyWith(position: logicalNow);
      final mid = _state.mediaId;
      if (mid != null) _savePosition(mid, logicalNow, force: true);
      _syncPlaybackStateToHandler();
      notifyListeners();
    } catch (e) {
      debugPrint('[MediaEngine] Screen on seek catch-up failed: $e');
    }
  }

  /// Restores video playback after the screen came back on.
  /// Returns true when the video controller is live again.
  Future<bool> _restoreNetworkVideo(Duration savedPosition) async {
    final mediaId = _state.mediaId;
    if (mediaId == null) return false;

    final last = _lastDirectUrl;
    if (last != null && last.startsWith('http')) {
      var uri = Uri.parse(last);
      if (_activeKind == MediaSourceKind.relayMerge &&
          savedPosition > Duration.zero) {
        // Merge streams restart at 0 — reconnect from the saved point.
        uri = _relayUriWithStart(uri, savedPosition);
      }
      try {
        final ok = await _startNetworkVideo(
          uri,
          mediaId,
          startAt: savedPosition,
          initTimeout: const Duration(seconds: 25),
          playToken: _playToken,
        );
        if (ok) playbackError = null;
        return ok;
      } catch (e) {
        debugPrint('[MediaEngine] Network restore error: $e');
        return false;
      }
    }

    try {
      await _restoreNetworkVideoFromYouTube(savedPosition);
      return _videoController != null && _videoController!.value.isInitialized;
    } catch (e) {
      debugPrint('[MediaEngine] YouTube restore error: $e');
      return false;
    }
  }

  /// Resolves the audio-only source ahead of the screen-off handoff.
  ///
  /// Only YouTube needs the network; local files and the last direct URL are
  /// instant and are resolved lazily at handoff time.
  Future<void> _warmBackgroundAudio(String mediaId) async {
    if (_parseVideoIdFromUrl(mediaId) == null) return;
    if (_warmAudioMediaId == mediaId && _warmAudioSource != null) return;
    final offsetBefore = _bgAudioOffset;
    try {
      final source = await _prepareBackgroundAudio(mediaId, Duration.zero);
      // Warming up must never move the position math of the live video.
      _bgAudioOffset = offsetBefore;
      if (source == null || _state.mediaId != mediaId) return;
      _warmAudioSource = source;
      _warmAudioMediaId = mediaId;
      debugPrint('[MediaEngine] background audio pre-resolved for $mediaId');
    } catch (e) {
      _bgAudioOffset = offsetBefore;
      debugPrint('[MediaEngine] background audio warm-up failed: $e');
    }
  }

  /// Backgrounds the YouTube video as an audio-only stream (data saving).
  /// Returns true when the background player is live.
  /// Resolves the background audio source for [mediaId] WITHOUT touching the
  /// video: the screen-off handoff must never open a hole in the sound.
  /// Sets [_bgAudioOffset] to the position the returned URL already starts
  /// at (only a relay `?t=` stream needs it) and returns null when there is
  /// nothing to hand off to.
  Future<AudioSource?> _prepareBackgroundAudio(
    String mediaId,
    Duration from,
  ) async {
    _bgAudioOffset = Duration.zero;
    final item = _createMediaItemFromState();

    // 1) Local or content:// source: plain file streaming, no URL expiry.
    final uri = _resolvePlaybackUriById(mediaId);
    if (uri != null) return AudioSource.uri(uri, tag: item);

    // 2) YouTube: audio-only variant (saves data on long videos). This is
    // where the resolution time used to be paid with the sound off.
    final videoId = _parseVideoIdFromUrl(mediaId);
    if (videoId != null) {
      try {
        final manifest = await _ytc.videos.streamsClient
            .getManifest(videoId)
            .timeout(const Duration(seconds: 10));
        final audioStreams = manifest.audioOnly.toList()
          ..sort((a, b) =>
              b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
        if (audioStreams.isNotEmpty) {
          return AudioSource.uri(audioStreams.first.url, tag: item);
        }
      } catch (e) {
        debugPrint('[MediaEngine] Background audio resolve failed: $e');
      }
    }

    // 3) Any direct stream (external mp4, proxy, relay merge): the last live
    // URL. Merge streams have no index, so reconnect from `?t=` instead of
    // seeking — and tell the position listener about the offset.
    final last = _lastDirectUrl;
    if (last != null && last.startsWith('http')) {
      var streamUri = Uri.parse(last);
      if (_activeKind == MediaSourceKind.relayMerge && from > Duration.zero) {
        streamUri = _relayUriWithStart(streamUri, from);
        _bgAudioOffset = from;
      }
      return AudioSource.uri(
        streamUri,
        tag: item,
        headers: ApiConfig.streamHeaders,
      );
    }
    return null;
  }

  /// Restores a local video after the screen came back on. Returns true when
  /// the controller is live again. The background audio is left untouched:
  /// the caller stops it once the video took over, so the swap is silent.
  Future<bool> _restoreLocalVideo(File file, Duration savedPosition) async {
    final controller = VideoPlayerController.file(file);
    _videoController = controller;
    try {
      await controller.initialize();
      await controller.seekTo(savedPosition);
      controller.addListener(() {
        if (!identical(_videoController, controller)) return;
        if (!controller.value.isInitialized) return;
        if (controller.value.hasError) return;
        final pos = controller.value.position;
        final dur = controller.value.duration;
        _state = _state.copyWith(position: pos, duration: dur);
        final mid = _state.mediaId;
        if (mid != null) _savePosition(mid, pos);
        _syncPlaybackStateToHandler();
        if (!_completionHandled && pos >= dur && dur > Duration.zero) {
          _completionHandled = true;
          _handlePlaybackComplete();
        }
        notifyListeners();
      });
      _state =
          _state.copyWith(status: MediaStatus.playing, position: savedPosition);
      _syncPlaybackStateToHandler();
      notifyListeners();
      await controller.play();
      return true;
    } catch (e) {
      debugPrint('[MediaEngine] Screen on video restore error: $e');
      await controller.dispose();
      if (identical(_videoController, controller)) _videoController = null;
      return false;
    }
  }

  Future<void> _restoreNetworkVideoFromYouTube(Duration savedPosition) async {
    final mediaId = _state.mediaId;
    if (mediaId == null) return;
    final videoId = _parseVideoIdFromUrl(mediaId);
    if (videoId == null) return;
    try {
      final manifest = await _ytc.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 12));
      final muxedStream = _bestMuxedStream(manifest);
      if (muxedStream == null) return;
      await _startNetworkVideo(muxedStream.url, mediaId, startAt: savedPosition);
    } catch (e) {
      debugPrint('[MediaEngine] YouTube video restore error: $e');
    }
  }

  Uri? _resolvePlaybackUriById(String mediaId) {
    if (mediaId.startsWith('content://')) {
      return Uri.parse(mediaId);
    }
    final localFile = StorageService.instance.getFile(mediaId);
    if (localFile != null) {
      return Uri.file(localFile.path);
    }
    return null;
  }

  // --- PiP ---

  Future<bool> enterPiP() async {
    if (isInPiP) return true;
    _isPiPEntering = true;
    final result = await PiPService.enterPiP();
    if (!result) {
      _isPiPEntering = false;
      return false;
    }
    debugPrint('[MediaEngine] PiP enter requested, awaiting system confirmation');
    _pipConfirmTimer?.cancel();
    _pipConfirmTimer = Timer(const Duration(seconds: 2), _confirmPiPEntry);
    return true;
  }

  Future<void> _confirmPiPEntry() async {
    if (_isInPiP) {
      _isPiPEntering = false;
      return;
    }
    final inPiP = await PiPService.isInPiP();
    if (!_isPiPEntering) return;
    _isInPiP = inPiP;
    _isPiPEntering = false;
    if (!inPiP) {
      debugPrint('[MediaEngine] PiP never started, lifecycle guard released');
    }
  }

  Future<bool> isPiPAvailable() async {
    return PiPService.isAvailable();
  }

  void onPiPEntered() {
    debugPrint('[MediaEngine] PiP entered, keeping video alive');
    _pipConfirmTimer?.cancel();
    _isPiPEntering = false;
    _isInPiP = true;
  }

  void onPiPExited() {
    debugPrint('[MediaEngine] PiP exited, restoring normal state');
    pipExitedAt = DateTime.now();
    _pipConfirmTimer?.cancel();
    _isInPiP = false;
    _isPiPEntering = false;
    if (_videoController != null && _state.isPlaying) {
      _videoController!.play();
    }
  }

  /// Offset added to the audio-player clock while background audio runs on
  /// a relay `?t=` stream (its clock restarts at 0 at that point). Zero for
  /// every other source. See `onScreenOff`.
  Duration _bgAudioOffset = Duration.zero;

  void _wireAudioSubscriptions(String mediaId) {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _errSub?.cancel();

    // A failed audio session (expired stream URL, unsupported codec, focus
    // refused) must never leave the UI claiming playback. This is what kept
    // "playing" on screen with no sound after a bad handoff.
    _errSub = _player.playbackEventStream.listen((_) {}, onError: (Object error) {
      final text = error is PlayerException
          ? '${error.code}: ${error.message}'
          : error.toString();
      debugPrint('[MediaEngine] audio error: $text');
      _lastAudioError = _short(text);
      if (_isAudioBackgroundActive && _videoController == null) {
        _state = _state.copyWith(status: MediaStatus.paused);
        _isAudioBackgroundActive = false;
        _syncPlaybackStateToHandler();
        notifyListeners();
      }
    });

    _posSub = _player.positionStream.listen((pos) {
      final logical = pos + _bgAudioOffset;
      _state = _state.copyWith(position: logical);
      _savePosition(mediaId, logical);
      _syncPlaybackStateToHandler();
      notifyListeners();
    });

    _durSub = _player.durationStream.listen((dur) {
      if (dur != null) {
        _state = _state.copyWith(duration: dur);
        if (_audioHandler?.mediaItem.value != null) {
          _audioHandler?.updateMediaItem(_audioHandler!.mediaItem.value!.copyWith(duration: dur));
        }
        _emitSessionSnapshot();
        notifyListeners();
      }
    });

    _stateSub = _player.playerStateStream.listen((playerState) {
      final playing = playerState.playing;
      final processingState = playerState.processingState;

      MediaStatus status;
      if (processingState == ProcessingState.completed) {
        if (!_completionHandled) {
          _completionHandled = true;
          status = MediaStatus.completed;
          _handlePlaybackComplete();
        } else {
          status = MediaStatus.completed;
        }
      } else if (processingState == ProcessingState.buffering) {
        status = MediaStatus.buffering;
      } else if (processingState == ProcessingState.loading) {
        status = MediaStatus.loading;
      } else if (playing) {
        status = MediaStatus.playing;
      } else {
        status = MediaStatus.paused;
      }

      _state = _state.copyWith(status: status);
      _syncPlaybackStateToHandler();
      notifyListeners();
    });
  }

  // --- Playback Complete ---

  void _handlePlaybackComplete() {
    _completionDebounce?.cancel();
    _completionDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (_queue.isEmpty) return;
      if (_state.repeatMode == PlayerRepeatMode.one) {
        // Repeat-one loops the SAME item forever (audio AND video).
        await seek(Duration.zero);
        if (_videoController != null) {
          await _videoController!.play();
        } else {
          unawaited(_player.play());
        }
        return;
      }
      // Repeat-all / shuffle / normal all flow through the same navigation
      // so completion behaves exactly like pressing "next".
      await skipToNext();
    });
  }

  // --- Transport Controls ---

  void seekProgress(double value) {
    final target = Duration(
      milliseconds: (_state.duration.inMilliseconds * value).round(),
    );
    seek(target);
  }

  @override
  Future<void> seek(Duration position) async {
    if (position < Duration.zero) position = Duration.zero;
    final mid = _state.mediaId;
    final c = _videoController;
    if (c != null) {
      if (_activeKind == MediaSourceKind.relayMerge &&
          _lastDirectUrl != null) {
        // Index-less merge stream: an in-player seek does nothing. Reconnect
        // the relay from that point (ffmpeg -ss server-side) instead.
        final reconnected = await _seekRelayMerge(position);
        if (reconnected) {
          _state = _state.copyWith(position: position);
          if (mid != null) _savePosition(mid, position, force: true);
          _syncPlaybackStateToHandler();
          notifyListeners();
          return;
        }
        // Reconnect failed: fall through to the in-player seek attempt.
      }
      await c.seekTo(position);
    } else {
      await _player.seek(position);
    }
    _state = _state.copyWith(position: position);
    if (mid != null) _savePosition(mid, position, force: true);
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  /// Reconnects the relay merge endpoint starting at [position].
  /// Returns true when the new stream initialized successfully.
  Future<bool> _seekRelayMerge(Duration position) async {
    final base = Uri.tryParse(_lastDirectUrl!);
    if (base == null) return false;
    final uri = _relayUriWithStart(base, position);
    final mediaId = _state.mediaId;
    if (mediaId == null) return false;
    final started = await _startNetworkVideo(
      uri,
      mediaId,
      startAt: position,
      initTimeout: const Duration(seconds: 25),
      playToken: _playToken,
    );
    if (started) playbackError = null;
    return started;
  }

  double _speed = 1.0;
  double get speed => _speed;

  /// Playback speed shared by audio and video (shown in player + session).
  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.25, 3.0);
    try {
      if (_videoController != null) {
        await _videoController!.setPlaybackSpeed(_speed);
      } else {
        await _player.setSpeed(_speed);
      }
    } catch (_) {}
    _emitSessionSnapshot();
    notifyListeners();
  }

  /// Per-video output volume 0..1 (used by the vertical-drag gesture).
  Future<void> setVideoVolume(double v) async {
    final c = _videoController;
    if (c == null) return;
    try {
      await c.setVolume(v.clamp(0.0, 1.0));
    } catch (_) {}
    notifyListeners();
  }

  double get videoVolume {
    try {
      return _videoController?.value.volume ?? 1.0;
    } catch (_) {
      return 1.0;
    }
  }

  Future<void> skipForward([Duration duration = const Duration(seconds: 15)]) async {
    final newPos = _state.position + duration;
    final clamped = newPos > _state.duration ? _state.duration : newPos;
    await seek(clamped);
  }

  Future<void> skipBackward([Duration duration = const Duration(seconds: 15)]) async {
    final newPos = _state.position - duration;
    await seek(newPos < Duration.zero ? Duration.zero : newPos);
  }

  @override
  Future<void> pause() async {
    if (_videoController != null) {
      await _videoController!.pause();
    } else {
      await _player.pause();
    }
    _state = _state.copyWith(status: MediaStatus.paused);
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  @override
  Future<void> resume() async {
    // A resolution chain is already running for the item the user picked.
    // It ends in play() by itself (_startNetworkVideo), so the play intent
    // is already queued and there is nothing to restart. Calling play() on
    // a player with no source is not merely useless: in just_audio a play
    // request with no audio source never completes, so the await hangs
    // forever, `status` is never updated and the user has to press again
    // once the stall watchdog has failed the play (~30-45s later). That is
    // exactly the "have to press Play twice" bug.
    if (_state.status == MediaStatus.loading ||
        _state.status == MediaStatus.buffering) {
      return;
    }
    // Idle/completed means there is NO live source (e.g. after a failed
    // video play): re-play the current queue item from scratch so state
    // (thumbnail, duration, subscriptions, handler) is fully rebuilt.
    // Blindly calling play() here would resume a stale player: audio from
    // another track (or silence) with frozen position and no artwork.
    if (_state.status == MediaStatus.idle ||
        _state.status == MediaStatus.completed) {
      if (_currentIndex >= 0 && _currentIndex < _queue.length) {
        playbackError = null;
        _completionHandled = false;
        _playToken++;
        final item = _queue[_currentIndex];
        final videoId = _parseVideoIdFromUrl(item.id);
        if (videoId != null && _state.mediaType == MediaType.video) {
          // A failed Explorer video retries the FULL pipeline first
          // (video, then the audio fallbacks inside) — from the saved
          // position, so the notification play never restarts at 0:00.
          await _playYouTubeVideo(item.id, item,
              startAt: await _resumePositionFor(item.id));
        } else {
          await _playCurrentQueueItem();
        }
        return;
      }
    }
    if (_videoController != null) {
      await _videoController!.play();
    } else if (_player.audioSource != null) {
      // NOT awaited: play() completes when playback ends, so awaiting it left
      // the state below "paused" forever and the user had to press Play a
      // second time to make the UI catch up.
      unawaited(_player.play());
    } else {
      // No source at all: there is nothing to resume. Forcing `playing`
      // here would hide the spinner and disarm the stall watchdog on a
      // chain that has not produced a player yet.
      return;
    }
    _state = _state.copyWith(status: MediaStatus.playing);
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (_state.isPlaying) {
      await pause();
    } else {
      await resume();
    }
  }

  // --- Stop / Dispose ---

  Future<void> _stopCurrentSilent() async {
    _completionDebounce?.cancel();
    // Every resolution candidate used to run a FULL teardown, even though
    // _playQueueItemVideo had already stopped the previous item: that
    // re-stopped the player and re-wrote the resume position once per
    // candidate for nothing. Only tear down when something is actually live.
    final live = _videoController != null ||
        _posSub != null ||
        _durSub != null ||
        _isAudioBackgroundActive;
    if (!live) return;
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _expectedDuration = null;

    if (_state.mediaId != null && _state.position.inMilliseconds > 0) {
      // force: this is the last write for this item, throttling must not drop
      // the resume point. It is NOT awaited: the player does not need the
      // write to be finished to stop, and awaiting it put a disk round-trip
      // in front of every new play (the position is captured synchronously,
      // so a later save for the next item cannot clobber it).
      unawaited(_savePosition(_state.mediaId!, _state.position, force: true));
    }

    try {
      await _player.stop();
    } catch (_) {}

    await _videoController?.dispose();
    _videoController = null;
    _isAudioBackgroundActive = false;
  }

  Future<void> _stopCurrent() async {
    _completionDebounce?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _expectedDuration = null;

    if (_state.mediaId != null && _state.position.inMilliseconds > 0) {
      // force: this is the last write for this item, throttling must not
      // drop the resume point. Fire-and-forget for the same reason as
      // _stopCurrentSilent: a disk round-trip must not delay the new play.
      unawaited(_savePosition(_state.mediaId!, _state.position, force: true));
    }

    try {
      await _player.stop();
    } catch (_) {}

    await _videoController?.dispose();
    _videoController = null;
    _isAudioBackgroundActive = false;
  }

  @override
  Future<void> stop() async {
    _playToken++;
    await _stopCurrent();
    _state = MediaState();
    _syncPlaybackStateToHandler();
    _queue.clear();
    _currentIndex = -1;
    _audioHandler?.queue.add([]);
    _audioHandler?.mediaItem.add(null);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _completionDebounce?.cancel();
    _pipConfirmTimer?.cancel();
    _playWatchdog?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _errSub?.cancel();
    for (final sub in _audioSessionSubs) {
      sub.cancel();
    }
    _sessionSnapshots.close();
    _stopCurrent();
    _audioHandler?.dispose();
    _ytc.close();
    super.dispose();
  }
}
