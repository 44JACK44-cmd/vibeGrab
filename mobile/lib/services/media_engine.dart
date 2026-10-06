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
  bool get isPlaying => _state.isPlaying;
  bool get isVideo => _state.mediaType == MediaType.video;
  bool get hasVideoController => _videoController != null;
  VideoPlayerController? get videoController => _videoController;
  AudioPlayer get audioPlayer => _player;
  Duration get position => _state.position;
  Duration get duration => _state.duration;

  // --- OS media session snapshot (single source of truth) ---

  final _sessionSnapshots = StreamController<SessionSnapshot>.broadcast();

  @override
  SessionSnapshot get currentSessionSnapshot => SessionSnapshot(
        position: _state.position,
        duration: _state.duration,
        bufferedPosition:
            _videoController != null ? Duration.zero : _player.bufferedPosition,
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
    return (_state.position.inMilliseconds / _state.duration.inMilliseconds).clamp(0.0, 1.0);
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
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Future<void> _loadPosition(String mediaId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt('${_prefix}${mediaId}_pos') ?? 0;
      _state = _state.copyWith(position: Duration(milliseconds: ms));
    } catch (_) {}
  }

  Future<void> _savePosition(String mediaId, Duration position) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('${_prefix}${mediaId}_pos', position.inMilliseconds);
    } catch (_) {}
  }

  Future<void> clearResumePosition(String mediaId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_prefix}${mediaId}_pos');
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

  String? _parseVideoIdFromUrl(String url) {
    final sanitized = url.trim();
    final idMatch = RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})').firstMatch(sanitized);
    if (idMatch != null) return idMatch.group(1);
    final uri = Uri.tryParse(sanitized);
    if (uri == null) return null;
    if (uri.host.contains('youtube.com') || uri.host.contains('youtu.be')) {
      if (uri.host.contains('youtu.be')) {
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        if (id != null && id.length == 11) return id;
      }
      final vParam = uri.queryParameters['v'];
      if (vParam != null && vParam.length == 11) return vParam;
      if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'shorts') {
        final id = uri.pathSegments.last;
        if (id.length == 11) return id;
      }
    }
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
    return MediaItem(
      id: video.url,
      title: video.title,
      artist: video.channel ?? 'YouTube',
      artUri: artUri,
      duration: video.duration != null ? Duration(seconds: video.duration!) : null,
    );
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
    final item = _queue[_currentIndex];
    _completionHandled = false;

    final libFile = _resolveLibraryFileFromExtras(item.extras);
    if (libFile != null) {
      await _playLocalFile(libFile);
    } else {
      final videoId = _parseVideoIdFromUrl(item.id);
      if (videoId != null) {
        await _playYouTubeAudio(item.id, item);
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

    await _playYouTubeAudio(url, item);
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

  Future<void> playExploreVideo(ExploreVideo video) async {
    await _stopCurrent();
    final item = _exploreVideoToMediaItem(video);
    _queue.add(item);
    _currentIndex = _queue.length - 1;
    _completionHandled = false;
    playbackError = null;

    _state = _state.copyWith(
      mediaId: video.url,
      title: video.title,
      artist: video.channel,
      thumbnail: video.thumbnail,
      mediaType: MediaType.video,
      status: MediaStatus.loading,
    );
    _syncToAudioHandler(item);
    _syncQueueToHandler();
    notifyListeners();

    // Stall watchdog: fails the play if nothing moves for 45s. It re-arms
    // itself on every resolution stage (see _setStage), so a progressing
    // chain is never killed.
    _armWatchdog(video.url);

    await _playYouTubeVideo(video.url, item);
  }

  // --- YouTube Video Playback ---
  //
  // Strategy (backend first): the on-device manifest is frequently
  // bot-blocked on mobile networks and burns 10s doing nothing. The warm
  // backend resolves stream URLs in seconds, and its proxy/relay endpoints
  // sidestep the googlevideo IP lockout. Resolved URLs are cached per video
  // so retries are instant instead of starting from zero.

  final Map<String, _CachedStreams> _streamUrlCache = {};
  static const _streamCacheTtl = Duration(hours: 4);

  /// Current resolution step, shown under the loading spinner.
  /// Holds an ARB key (see playStage*), null when not resolving.
  String? loadingStageKey;
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

  Uri _proxyUri(String target) =>
      Uri.parse('${ApiConfig.baseUrl}/api/explore/proxy')
          .replace(queryParameters: {'u': target});

  Future<StreamUrls?> _fetchStreamUrlsCached(String videoId) async {
    final hit = _streamUrlCache[videoId];
    if (hit != null &&
        DateTime.now().difference(hit.at) < _streamCacheTtl) {
      debugPrint('[MediaEngine] Stream URLs from cache for $videoId');
      return hit.urls;
    }
    final urls = await _fetchStreamUrls(videoId);
    if (urls != null) {
      _streamUrlCache[videoId] = _CachedStreams(urls, DateTime.now());
    }
    return urls;
  }

  Future<void> _playYouTubeVideo(String youtubeUrl, MediaItem mediaItem) async {
    final videoId = _parseVideoIdFromUrl(youtubeUrl);
    if (videoId == null) {
      debugPrint('[MediaEngine] Invalid YouTube URL: $youtubeUrl');
      _clearStage();
      _failPlayback('URL inválida');
      return;
    }
    final errs = <String>[];

    // 1) Server stream URLs first (fast + warm; cached per video).
    _setStage('playStageServer');
    final urls = await _fetchStreamUrlsCached(videoId);
    if (urls == null) {
      errs.add('servidor: ${_lastStreamError ?? "sin url"}');
    } else {
      // 1a) Server-forwarded video bytes: no IP lockout, seeking works.
      if (urls.video != null) {
        final started = await _tryStartNetworkVideo(
            _proxyUri(urls.video!), youtubeUrl, mediaItem,
            initTimeout: const Duration(seconds: 18));
        if (started) {
          _clearStage();
          return;
        }
        errs.add('video: ${_lastVideoError ?? "init falló"}');
      }
      // 1b) Relay path.
      if (urls.proxy != null) {
        final started = await _tryStartNetworkVideo(
            Uri.parse('${ApiConfig.baseUrl}${urls.proxy!}'),
            youtubeUrl, mediaItem,
            initTimeout: const Duration(seconds: 20));
        if (started) {
          _clearStage();
          return;
        }
        errs.add('relé: ${_lastVideoError ?? "init falló"}');
      }
      // 1c) Server-forwarded audio (full state: thumbnail + time work).
      if (urls.audio != null) {
        _setStage('playStageAudio');
        final ok = await _playYouTubeAudio(youtubeUrl, mediaItem,
            streamUri: _proxyUri(urls.audio!));
        if (ok) {
          _clearStage();
          return;
        }
        errs.add('audio: ${_lastAudioError ?? "falló"}');
      }
    }

    // 2) Direct device manifest (last resort: often bot-blocked on mobile).
    _setStage('playStageDirect');
    StreamManifest? manifest;
    try {
      manifest = await _ytc.videos.streamsClient.getManifest(videoId).timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('Stream manifest timed out'),
      );
    } catch (e) {
      debugPrint('[MediaEngine] Device stream path failed: $e');
      errs.add('directo: ${_short(e.toString())}');
    }
    if (manifest != null) {
      final muxedStream = _bestMuxedStream(manifest);
      if (muxedStream != null) {
        final started = await _tryStartNetworkVideo(
            muxedStream.url, youtubeUrl, mediaItem,
            initTimeout: const Duration(seconds: 12));
        if (started) {
          _clearStage();
          return;
        }
        errs.add('directo: ${_lastVideoError ?? "init falló"}');
      }
      _setStage('playStageAudio');
      final ok =
          await _playYouTubeAudio(youtubeUrl, mediaItem, manifest: manifest);
      if (ok) {
        _clearStage();
        return;
      }
      errs.add('audio directo: ${_lastAudioError ?? "falló"}');
    }

    _clearStage();
    final detail = errs.join(' · ');
    _failPlayback(detail.isEmpty
        ? 'no reproducible'
        : '${detail.length > 280 ? '${detail.substring(0, 280)}…' : detail}');
  }

  static String _short(String s) => s.length > 70 ? s.substring(0, 70) : s;

  Future<bool> _tryStartNetworkVideo(
      Uri streamUrl, String youtubeUrl, MediaItem mediaItem,
      {Duration initTimeout = const Duration(seconds: 15)}) async {
    await _stopCurrentSilent();
    _state = _state.copyWith(
      mediaId: youtubeUrl,
      title: mediaItem.title,
      artist: mediaItem.artist ?? 'YouTube',
      thumbnail: mediaItem.artUri?.toString(),
      mediaType: MediaType.video,
      status: MediaStatus.buffering,
    );
    _syncToAudioHandler(mediaItem);
    notifyListeners();

    final started =
        await _startNetworkVideo(streamUrl, youtubeUrl, initTimeout: initTimeout);
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

  Future<StreamUrls?> _fetchStreamUrls(String videoId) async {
    _lastStreamError = null;
    // One immediate retry: a sleeping backend (cold start) answers 502 or
    // times out once, then serves normally. Without this, the first play
    // after a while always fails.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final response = await http
            .get(Uri.parse('${ApiConfig.exploreStreamUrl}?v=$videoId'))
            .timeout(const Duration(seconds: 15));
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
      if (attempt == 0) {
        await Future.delayed(const Duration(seconds: 2));
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
  }) async {
    _lastVideoError = null;
    await _videoController?.dispose();
    final controller = VideoPlayerController.networkUrl(
      streamUrl,
      httpHeaders: const {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
      },
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

      if (startAt > Duration.zero) {
        await controller.seekTo(startAt);
      }

      controller.addListener(() {
        if (!identical(_videoController, controller)) return;
        if (!controller.value.isInitialized) return;
        if (controller.value.hasError) return;
        final pos = controller.value.position;
        final dur = controller.value.duration;
        _state = _state.copyWith(position: pos, duration: dur);
        _savePosition(mediaId, pos);
        _syncPlaybackStateToHandler();

        if (!_completionHandled && pos >= dur && dur > Duration.zero) {
          _completionHandled = true;
          _handlePlaybackComplete();
        }
        notifyListeners();
      });

      _state = _state.copyWith(status: MediaStatus.playing, position: startAt);
      _syncPlaybackStateToHandler();
      notifyListeners();
      await controller.play();
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
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36',
            },
          ))
          .timeout(const Duration(seconds: 20));
      _wireAudioSubscriptions(youtubeUrl);

      playbackError = null;
      _state = _state.copyWith(status: MediaStatus.playing, position: Duration.zero);
      _syncPlaybackStateToHandler();
      notifyListeners();
      await _player.play();

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
    debugPrint('[MediaEngine] _playLocalFile: ${file.title}, type=${file.fileType}, hasContentUri=${file.hasContentUri}');
    final mediaId = file.hasContentUri ? file.contentUri! : file.filename;
    final video = file.isVideo;

    final artUri = _resolveArtUri(file);
    final thumbnailPath = file.thumbnailPath;
    final mediaItem = MediaItem(
      id: mediaId,
      title: file.title,
      artist: file.source ?? 'VibeGrab',
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
      title: file.title,
      artist: file.source,
      thumbnail: file.thumbnail,
      thumbnailPath: thumbnailPath,
      mediaType: video ? MediaType.video : MediaType.audio,
      status: MediaStatus.loading,
    );
    _syncToAudioHandler(mediaItem);
    notifyListeners();

    MediaMetadataService().recordPlay(
      filename: file.filename,
      title: file.title,
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
      await _player.play();
      debugPrint('[MediaEngine] _player.play() completed');
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
    await _player.play();
  }

  Future<void> _playVideoFile(File file, MediaItem item) async {
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
      _videoController = VideoPlayerController.networkUrl(uri);
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

    final savedPosition = _videoController!.value.position;
    final savedDuration = _videoController!.value.duration;

    await _videoController?.dispose();
    _videoController = null;

    final uri = _resolvePlaybackUriById(_state.mediaId!);
    if (uri == null) {
      await _startBackgroundAudioForYouTube(savedPosition);
      return;
    }

    final item = _createMediaItemFromState();
    try {
      await _player.setAudioSource(AudioSource.uri(uri, tag: item));
      await _player.seek(savedPosition);
      await _player.play();
    } catch (e) {
      debugPrint('[MediaEngine] Screen off audio fallback error: $e');
      return;
    }

    _wireAudioSubscriptions(_state.mediaId!);

    _state = _state.copyWith(
      status: MediaStatus.playing,
      position: savedPosition,
      duration: savedDuration,
    );
    _isAudioBackgroundActive = true;
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  Future<void> onScreenOn() async {
    if (!_isAudioBackgroundActive) return;

    final savedPosition = _player.position;

    try {
      await _player.stop();
    } catch (_) {}
    _isAudioBackgroundActive = false;

    if (_state.mediaId != null) {
      final localFile = StorageService.instance.getFile(_state.mediaId!);
      if (localFile != null && localFile.existsSync()) {
        _videoController = VideoPlayerController.file(localFile);
        try {
          await _videoController!.initialize();
          await _videoController!.seekTo(savedPosition);
          _videoController!.addListener(() {
            if (_videoController == null || !_videoController!.value.isInitialized) return;
            if (_videoController!.value.hasError) return;
            final pos = _videoController!.value.position;
            final dur = _videoController!.value.duration;
            _state = _state.copyWith(position: pos, duration: dur);
            _savePosition(_state.mediaId!, pos);
            _syncPlaybackStateToHandler();
            if (!_completionHandled && pos >= dur && dur > Duration.zero) {
              _completionHandled = true;
              _handlePlaybackComplete();
            }
            notifyListeners();
          });
          _state = _state.copyWith(status: MediaStatus.playing, position: savedPosition);
          _syncPlaybackStateToHandler();
          notifyListeners();
          await _videoController!.play();
        } catch (e) {
          debugPrint('[MediaEngine] Screen on video restore error: $e');
        }
      } else {
        await _restoreNetworkVideoFromYouTube(savedPosition);
      }
    }
  }

  Future<void> _startBackgroundAudioForYouTube(Duration savedPosition) async {
    final mediaId = _state.mediaId;
    if (mediaId == null) return;
    final videoId = _parseVideoIdFromUrl(mediaId);
    if (videoId == null) return;
    try {
      final manifest = await _ytc.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 10));
      final audioStreams = manifest.audioOnly.toList()
        ..sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      if (audioStreams.isEmpty) return;

      final item = _createMediaItemFromState();
      await _player.setAudioSource(
          AudioSource.uri(audioStreams.first.url, tag: item));
      await _player.seek(savedPosition);
      await _player.play();
      _wireAudioSubscriptions(mediaId);
      _isAudioBackgroundActive = true;
      _syncPlaybackStateToHandler();
      notifyListeners();
    } catch (e) {
      debugPrint('[MediaEngine] YouTube background audio error: $e');
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

  void _wireAudioSubscriptions(String mediaId) {
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();

    _posSub = _player.positionStream.listen((pos) {
      _state = _state.copyWith(position: pos);
      _savePosition(mediaId, pos);
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
          await _player.play();
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

  Future<void> seek(Duration position) async {
    if (_videoController != null) {
      await _videoController!.seekTo(position);
    } else {
      await _player.seek(position);
    }
    _state = _state.copyWith(position: position);
    _syncPlaybackStateToHandler();
    notifyListeners();
  }

  double _speed = 1.0;
  double get speed => _speed;

  /// Playback speed shared by audio and video (shown in player + session).
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

  Future<void> resume() async {
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
        final item = _queue[_currentIndex];
        final videoId = _parseVideoIdFromUrl(item.id);
        if (videoId != null && _state.mediaType == MediaType.video) {
          // A failed Explorer video retries the FULL pipeline first
          // (video, then the audio fallbacks inside).
          await _playYouTubeVideo(item.id, item);
        } else {
          await _playCurrentQueueItem();
        }
        return;
      }
    }
    if (_videoController != null) {
      await _videoController!.play();
    } else {
      await _player.play();
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
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();

    if (_state.mediaId != null && _state.position.inMilliseconds > 0) {
      await _savePosition(_state.mediaId!, _state.position);
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

    if (_state.mediaId != null && _state.position.inMilliseconds > 0) {
      await _savePosition(_state.mediaId!, _state.position);
    }

    try {
      await _player.stop();
    } catch (_) {}

    await _videoController?.dispose();
    _videoController = null;
    _isAudioBackgroundActive = false;
  }

  Future<void> stop() async {
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
    _completionDebounce?.cancel();
    _pipConfirmTimer?.cancel();
    _playWatchdog?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
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

/// Server stream URLs resolved for one video, with fetch time (TTL enforced
/// by callers). Retries reuse them instead of resolving from zero.
class _CachedStreams {
  final StreamUrls urls;
  final DateTime at;
  const _CachedStreams(this.urls, this.at);
}
