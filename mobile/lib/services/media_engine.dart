import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../data/models/media_state.dart';
import '../data/models/library_file.dart';
import '../data/models/explore_video.dart';
import '../services/storage_service.dart';
import '../services/media_metadata_service.dart';
import '../services/vibe_grab_audio_handler.dart';
import '../services/pip_service.dart';

class MediaEngine extends ChangeNotifier implements MediaEngineDelegate {
  final AudioPlayer _player = AudioPlayer();
  VideoPlayerController? _videoController;
  VibeGrabAudioHandler? _audioHandler;
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

  bool _isAudioBackgroundActive = false;
  bool get isAudioBackgroundActive => _isAudioBackgroundActive;

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
  bool get hasNext => _currentIndex < _queue.length - 1 || _state.repeatMode == PlayerRepeatMode.all;
  bool get hasPrevious => _currentIndex > 0 || _state.repeatMode == PlayerRepeatMode.all;

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

  Future<void> initAudioService() async {
    try {
      debugPrint('[MediaEngine] Initializing AudioService...');
      PiPService.init();
      _audioHandler = VibeGrabAudioHandler(this);
      await AudioService.init(
        builder: () => _audioHandler!,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.example.vibegrab.audio',
          androidNotificationChannelName: 'VibeGrab Audio',
          androidNotificationChannelDescription: 'VibeGrab media playback controls',
          androidNotificationIcon: 'drawable/ic_music_note',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          preloadArtwork: true,
        ),
      );
      debugPrint('[MediaEngine] AudioService initialized successfully');
    } catch (e) {
      debugPrint('[MediaEngine] AudioService init FAILED: $e');
    }
  }

  void _syncToAudioHandler(MediaItem item) {
    debugPrint('[MediaEngine] Syncing to handler: ${item.title}, artUri=${item.artUri}');
    _audioHandler?.updateMediaItem(item);
    _syncPlaybackStateToHandler();
  }

  void _syncPlaybackStateToHandler() {
    AudioProcessingState procState;
    switch (_state.status) {
      case MediaStatus.idle:
        procState = AudioProcessingState.idle;
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
    _audioHandler?.updatePlaybackState(
      playing: _state.isPlaying,
      processingState: procState,
    );
  }

  void _syncQueueToHandler() {
    _audioHandler?.queue.add(_queue);
    if (_currentIndex >= 0 && _currentIndex < _queue.length) {
      _audioHandler?.updateMediaItem(_queue[_currentIndex]);
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

  // --- Shuffle & Repeat ---

  void toggleShuffle() {
    _state = _state.copyWith(isShuffle: !_state.isShuffle);
    _player.setShuffleModeEnabled(_state.isShuffle);
    notifyListeners();
  }

  void toggleRepeat() {
    final modes = PlayerRepeatMode.values;
    final nextIndex = (modes.indexOf(_state.repeatMode) + 1) % modes.length;
    _state = _state.copyWith(repeatMode: modes[nextIndex]);
    switch (_state.repeatMode) {
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
    notifyListeners();
  }

  // --- Navigation ---

  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;
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

    _state = _state.copyWith(
      mediaId: video.url,
      title: video.title,
      artist: video.channel,
      thumbnail: video.thumbnail,
      mediaType: MediaType.audio,
      status: MediaStatus.loading,
    );
    _syncToAudioHandler(item);
    _syncQueueToHandler();
    notifyListeners();

    await _playYouTubeAudio(video.url, item);
  }

  // --- YouTube Audio Playback ---

  Future<void> _playYouTubeAudio(String youtubeUrl, MediaItem mediaItem) async {
    try {
      final videoId = _parseVideoIdFromUrl(youtubeUrl);
      if (videoId == null) {
        debugPrint('[MediaEngine] Invalid YouTube URL: $youtubeUrl');
        _state = _state.copyWith(status: MediaStatus.idle);
        notifyListeners();
        return;
      }

      final manifest = await _ytc.videos.streamsClient.getManifest(videoId)
          .timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException('Stream manifest timed out');
      });

      final audioStreams = manifest.audioOnly.toList()
        ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

      if (audioStreams.isEmpty) {
        debugPrint('[MediaEngine] No audio streams found for $youtubeUrl');
        _state = _state.copyWith(status: MediaStatus.idle);
        notifyListeners();
        return;
      }

      final streamUrl = audioStreams.first.url;

      _stopCurrentSilent();
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

      await _player.setAudioSource(AudioSource.uri(streamUrl, tag: mediaItem));
      _wireAudioSubscriptions(youtubeUrl);

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
    } catch (e) {
      debugPrint('[MediaEngine] YouTube audio play error: $e');
      _state = _state.copyWith(status: MediaStatus.idle);
      _syncPlaybackStateToHandler();
      notifyListeners();
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
        notifyListeners();
        return;
      }

      try {
        await _player.setAudioSource(AudioSource.uri(uri, tag: mediaItem));
      } catch (e) {
        debugPrint('[MediaEngine] Audio source error: $e');
        _state = _state.copyWith(status: MediaStatus.idle);
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
      notifyListeners();
      return;
    }

    if (_videoController!.value.hasError) {
      debugPrint('[MediaEngine] Video has error: ${_videoController!.value.errorDescription}');
      _state = _state.copyWith(status: MediaStatus.idle);
      await _videoController?.dispose();
      _videoController = null;
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
      notifyListeners();
      return;
    }

    if (_videoController!.value.hasError) {
      debugPrint('[MediaEngine] Video has error: ${_videoController!.value.errorDescription}');
      _state = _state.copyWith(status: MediaStatus.idle);
      await _videoController?.dispose();
      _videoController = null;
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
    if (!isVideo || _videoController == null) return;
    if (!_state.isPlaying) return;

    final savedPosition = _videoController!.value.position;
    final savedDuration = _videoController!.value.duration;

    await _videoController?.dispose();
    _videoController = null;

    final uri = _resolvePlaybackUriById(_state.mediaId!);
    if (uri == null) return;

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
      }
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

  Future<void> enterPiP() async {
    final result = await PiPService.enterPiP();
    if (result) {
      debugPrint('[MediaEngine] Entered PiP mode');
    }
  }

  Future<bool> isPiPAvailable() async {
    return PiPService.isAvailable();
  }

  // --- Audio Subscriptions ---

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
    _completionDebounce = Timer(const Duration(milliseconds: 300), () {
      if (_queue.isEmpty) return;
      switch (_state.repeatMode) {
        case PlayerRepeatMode.one:
          seek(Duration.zero);
          _player.play();
          break;
        case PlayerRepeatMode.all:
          skipToNext();
          break;
        case PlayerRepeatMode.none:
          if (_currentIndex < _queue.length - 1) {
            skipToNext();
          }
          break;
      }
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
    _audioHandler?.updatePlaybackState(
      playing: false,
      processingState: AudioProcessingState.idle,
    );
    _state = MediaState();
    _queue.clear();
    _currentIndex = -1;
    _audioHandler?.queue.add([]);
    _audioHandler?.mediaItem.add(null);
    notifyListeners();
  }

  @override
  void dispose() {
    _completionDebounce?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _stopCurrent();
    _audioHandler?.dispose();
    _ytc.close();
    super.dispose();
  }
}
