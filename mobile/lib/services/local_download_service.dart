import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import '../data/models/app_settings.dart';
import '../data/models/download_task.dart';
import '../services/storage_service.dart';
import '../services/local_extraction_service.dart';
import 'download_errors.dart';

class DownloadStep {
  final String step;
  final String? detail;
  const DownloadStep(this.step, [this.detail]);
}

class _CandidateStream {
  final StreamInfo stream;
  final bool needsMux;
  _CandidateStream(this.stream, this.needsMux);
}

/// One file of a multipart upload (the tracks the device already downloaded).
class _UploadPart {
  final String field;
  final String path;
  final String filename;
  const _UploadPart(this.field, this.path, this.filename);
}

class _IncompleteTransferException implements Exception {
  final int received;
  final int expected;
  const _IncompleteTransferException(this.received, this.expected);

  @override
  String toString() => 'Incomplete transfer: $received of $expected bytes';
}

class _DownloadCancelledException implements Exception {
  const _DownloadCancelledException();
}

class LocalDownloadService {
  final YoutubeExplode _ytc = YoutubeExplode();
  final Map<String, bool> _activeDownloads = {};

  void dispose() {
    _activeDownloads.clear();
    _ytc.close();
  }

  static String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
  }

  void _log(String msg) => debugPrint('[DOWNLOAD] ${_ts()} $msg');

  static const _youTubeHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept': '*/*',
    'Origin': 'https://www.youtube.com',
    'Referer': 'https://www.youtube.com/',
  };

  static Map<String, String> get _directHeaders => {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept-Language': 'en-US,en;q=0.9',
        'Accept': '*/*',
        ...ApiConfig.authHeaders,
      };

  /// Headers for a media request. The API key only travels to our own backend:
  /// a CDN (googlevideo, tiktokcdn, …) must never receive it.
  static Map<String, String> _headersFor(Uri uri) {
    final backend = Uri.tryParse(ApiConfig.baseUrl);
    if (backend != null && backend.host == uri.host) {
      return _directHeaders;
    }
    final host = uri.host;
    if (host.endsWith('googlevideo.com') ||
        host.endsWith('youtube.com') ||
        host.endsWith('ytimg.com')) {
      return _youTubeHeaders;
    }
    return {
      'User-Agent': ApiConfig.streamUserAgent,
      'Accept-Language': 'en-US,en;q=0.9',
      'Accept': '*/*',
    };
  }

  /// Failures worth retrying with another route (device streams, another
  /// format): the backend or the network may simply be having a bad moment.
  static const _retriableErrors = {
    DownloadErrorType.http403,
    DownloadErrorType.httpError,
    DownloadErrorType.sourceUnavailable,
    DownloadErrorType.unexpectedResponse,
    DownloadErrorType.connectionTimeout,
    DownloadErrorType.serverTimeout,
    DownloadErrorType.connectionFailed,
  };

  Future<void> _deleteIfExists(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A leftover partial file is not worth failing the fallback for.
    }
  }

  /// Scratch file for a track that still has to be re-encoded or muxed.
  ///
  /// Keeping it in the app cache (not in the user's Downloads folder) prevents
  /// the intermediate video/audio track from showing up in the library or the
  /// gallery next to the finished download.
  String _tempSourcePath(DownloadTask task, String suffix) {
    final safeId = task.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final dir = StorageService.instance.tempSourcesDir.path;
    return '$dir${Platform.pathSeparator}${safeId}_$suffix';
  }

  Future<DownloadTask> _downloadDirect({
    required DownloadTask task,
    required String dir,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
    String? formatIdOverride,
    String? extOverride,
  }) async {
    final ext = extOverride ?? _directExtension(task);
    final safeTitle = _sanitizeFilename(task.title);
    final filePath = '$dir/$safeTitle.$ext';
    final formatId = (formatIdOverride ?? task.formatId).trim();

    // Plain file (e.g. a video cover image): direct HTTP GET without the
    // yt-dlp relay, which only understands provider URLs.
    if (formatId.isEmpty) {
      final direct = task.directUrl;
      final uri = direct == null ? null : Uri.tryParse(direct);
      if (uri == null || uri.host.isEmpty) {
        _log('DIRECT FAILED: no direct URL for file download');
        return task.copyWith(
          status: 'failed',
          error: 'Invalid download URL',
          errorCode: 'invalidUrl',
        );
      }
      _log('DIRECT FILE: filePath=$filePath url=${uri.host}${uri.path}');
      if (!_activeDownloads.containsKey(task.id)) {
        return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
      }
      onStep(const DownloadStep('connecting', 'Connecting to server...'));
      onStep(const DownloadStep('downloading', 'Downloading...'));
      return _downloadViaHttpClient(
        url: uri,
        filePath: filePath,
        totalBytes: task.totalBytes ?? 0,
        onProgress: onProgress,
        task: task,
        headers: _headersFor(uri),
        responseTimeout: const Duration(seconds: 60),
        operation: 'direct_file',
      );
    }

    final fetchUri = Uri.tryParse(
      '${ApiConfig.baseUrl}/api/fetch'
      '?url=${Uri.encodeQueryComponent(task.url)}'
      '&format_id=${Uri.encodeQueryComponent(formatId)}'
      '&ext=${Uri.encodeQueryComponent(ext)}',
    );
    if (fetchUri == null) {
      _log('DIRECT FAILED: invalid fetch URL');
      return task.copyWith(status: 'failed', error: 'Invalid download URL', errorCode: 'invalidUrl');
    }

    _log('DIRECT: filePath=$filePath ext=$ext server=${ApiConfig.baseUrl} knownSize=${task.totalBytes}');

    if (!_activeDownloads.containsKey(task.id)) {
      return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
    }

    onStep(const DownloadStep('connecting', 'Connecting to server...'));
    onStep(const DownloadStep('downloading', 'Downloading...'));
    _log('DIRECT: Starting streaming download via backend...');

    final result = await _downloadViaHttpClient(
      url: fetchUri,
      filePath: filePath,
      totalBytes: task.totalBytes ?? 0,
      onProgress: onProgress,
      task: task,
      headers: _headersFor(fetchUri),
      responseTimeout: const Duration(seconds: 60),
      operation: 'fetch',
    );

    if (result.status == DownloadStatus.completed) {
      final expected = task.totalBytes ?? 0;
      if (expected > 0 && result.bytesDownloaded < (expected * 0.95).floor()) {
        _log('DIRECT FAILED: truncated ${result.bytesDownloaded} < expected $expected');
        try {
          await File(result.filePath!).delete();
        } catch (_) {}
        return task.copyWith(
          status: 'failed',
          error: 'Incomplete download',
          errorCode: 'fileEmpty',
          bytesDownloaded: 0,
          progress: 0,
        );
      }
      sw.stop();
      _log('===== COMPLETED (direct) id=${task.id} =====');
      _log('file=${result.filePath} size=${result.bytesDownloaded} (${(result.bytesDownloaded / 1024 / 1024).toStringAsFixed(1)} MB) time=${sw.elapsedMilliseconds}ms');
    }
    return result;
  }

  /// Real container of a direct media URL, independent of the format label.
  /// Provider URLs often end in `videoplayback` with no extension, so the
  /// `mime`/`ext` query parameters are checked first.
  String _directAudioExtension(Uri uri) {
    const known = {'mp3', 'm4a', 'mp4', 'aac', 'webm', 'ogg', 'opus'};
    final mime = (uri.queryParameters['mime'] ?? '').toLowerCase();
    if (mime.contains('audio/mpeg') || mime.contains('audio/mp3')) {
      return 'mp3';
    }
    if (mime.contains('audio/mp4') || mime.contains('audio/aac')) return 'm4a';
    if (mime.contains('audio/webm')) return 'webm';
    if (mime.contains('audio/ogg') || mime.contains('audio/opus')) return 'ogg';
    if (mime.contains('video/mp4')) return 'mp4';
    if (mime.contains('video/webm')) return 'webm';

    final queryExt = (uri.queryParameters['ext'] ?? '').toLowerCase();
    if (known.contains(queryExt)) return queryExt;

    final path = uri.path.toLowerCase();
    final dot = path.lastIndexOf('.');
    if (dot > -1 && dot < path.length - 1) {
      final ext = path.substring(dot + 1);
      if (known.contains(ext)) return ext;
    }
    return '';
  }

  String _directExtension(DownloadTask task) {
    final fromTask = task.fileExt?.trim();
    if (fromTask != null && fromTask.isNotEmpty && fromTask != 'none') return fromTask;
    final directUrl = task.directUrl;
    if (directUrl != null && directUrl.isNotEmpty) {
      final path = Uri.tryParse(directUrl)?.path ?? '';
      final dot = path.lastIndexOf('.');
      if (dot > -1 && dot < path.length - 1) {
        final ext = path.substring(dot + 1).toLowerCase();
        if (ext.length <= 5 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return ext;
      }
    }
    return task.mediaType == DownloadMediaType.audio ? 'm4a' : 'mp4';
  }

  String _getExtension(StreamInfo stream) {
    final mimeType = stream.codec.mimeType;
    if (mimeType.contains('audio/mp4') || mimeType == 'audio/mp4') return 'm4a';
    if (mimeType.contains('audio/webm') || mimeType == 'audio/webm') return 'webm';
    if (mimeType.contains('audio/ogg') || mimeType == 'audio/ogg') return 'ogg';
    final containerName = stream.container.name.toLowerCase();
    if (containerName == 'mp4') return 'm4a';
    if (containerName == 'webm') return 'webm';
    if (containerName == 'ogg') return 'ogg';
    return containerName;
  }

  String _getVideoExtension(StreamInfo stream) {
    final mimeType = stream.codec.mimeType;
    if (mimeType.contains('video/mp4') || mimeType == 'video/mp4') return 'mp4';
    if (mimeType.contains('video/webm') || mimeType == 'video/webm') return 'webm';
    final containerName = stream.container.name.toLowerCase();
    if (containerName == 'mp4') return 'mp4';
    if (containerName == 'webm') return 'webm';
    return containerName;
  }

  bool _streamHasVideo(StreamInfo stream) {
    if (stream is VideoOnlyStreamInfo) return true;
    if (stream is MuxedStreamInfo) return true;
    if (stream is AudioOnlyStreamInfo) return false;
    return false;
  }

  bool _streamHasAudio(StreamInfo stream) {
    if (stream is AudioOnlyStreamInfo) return true;
    if (stream is MuxedStreamInfo) return true;
    if (stream is VideoOnlyStreamInfo) return false;
    return false;
  }

  /// Real MP3.
  ///
  /// The provider binds a signed media URL to the IP that asked for it, and in
  /// production the backend host is blocked by the provider. So the device —
  /// which already has a working, signed URL from its own manifest — downloads
  /// the audio track and uploads those bytes; the backend only runs ffmpeg.
  /// Sources the server can reach itself (e.g. a photo post's music) still use
  /// the URL conversion, without an upload.
  ///
  /// A task that asked for MP3 never ends as an m4a/webm renamed to `.mp3`:
  /// when no real MP3 can be produced it fails with a typed error.
  @visibleForTesting
  bool wantsMp3(DownloadTask task) {
    final ext = (task.fileExt ?? '').trim().toLowerCase();
    final synthetic =
        task.formatId.trim().toLowerCase().endsWith('__mp3');
    // Tasks persisted by older builds could have media_type=video even for
    // the synthetic MP3 row. The extension and the synthetic id are stronger
    // evidence than that stale field, so route them through the real MP3
    // pipeline as well.
    if (synthetic) return true;
    if (task.mediaType != DownloadMediaType.audio) return false;
    if (ext.isEmpty) return true; // tasks saved by older versions
    return ext == 'mp3';
  }

  Future<DownloadTask> _downloadAudioAsMp3({
    required DownloadTask task,
    required String dir,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) async {
    final safeTitle = _sanitizeFilename(task.title);
    final filePath = '$dir/$safeTitle.mp3';
    final videoId = _parseVideoId(LocalExtractionService.sanitizeUrl(task.url));
    final tempFiles = <String>[];
    DownloadErrorType? lastError;

    // 1) The analyser already gave us a signed media URL. For a non-YouTube
    //    source, or an audio-only YouTube row, downloading it directly skips
    //    a whole extra manifest round-trip (1-3 s on a phone network).
    final directRaw = (task.directUrl ?? '').trim();
    final directUri = directRaw.isEmpty ? null : Uri.tryParse(directRaw);
    final synthetic = task.formatId.trim().toLowerCase().endsWith('__mp3');
    final canUseDirectFirst = directUri != null &&
        directUri.hasScheme &&
        directUri.host.isNotEmpty &&
        (videoId == null || !task.hasVideo || synthetic);
    if (canUseDirectFirst) {
      // The synthetic `__mp3` format has fileExt=mp3, but its directUrl is
      // the provider's m4a/webm/mp4 source that still needs conversion.
      // Trust the URL/mime, never the label, before copying bytes as MP3.
      final sourceExt = _directAudioExtension(directUri);
      final ext = sourceExt.isEmpty ? 'm4a' : sourceExt;
      if (ext == 'mp3') {
        // Already a real MP3 container: copy the bytes as-is, no re-encode.
        onStep(const DownloadStep('downloading', 'Downloading MP3...'));
        final direct = await _downloadViaHttpClient(
          url: directUri,
          filePath: filePath,
          totalBytes: task.totalBytes ?? 0,
          onProgress: onProgress,
          task: task,
          headers: _headersFor(directUri),
          responseTimeout: const Duration(seconds: 60),
          operation: 'mp3_direct',
        );
        if (direct.status == DownloadStatus.completed) return direct;
        lastError = direct.errorCode;
        if (!_retriableErrors.contains(direct.errorCode)) return direct;
      } else {
        final tempPath = _tempSourcePath(task, 'audio.$ext');
        tempFiles.add(tempPath);
        onStep(const DownloadStep('downloading', 'Downloading audio track...'));
        final track = await _downloadViaHttpClient(
          url: directUri,
          filePath: tempPath,
          totalBytes: task.totalBytes ?? 0,
          onProgress: _scaledProgressInRange(onProgress, 0.0, 0.5),
          task: task,
          headers: _headersFor(directUri),
          responseTimeout: const Duration(seconds: 60),
          operation: 'mp3_source',
        );
        if (track.status == DownloadStatus.completed) {
          return _convertToMp3(
            task: task,
            tempPath: tempPath,
            ext: ext,
            filePath: filePath,
            onProgress: onProgress,
            onStep: onStep,
            sw: sw,
          );
        }
        lastError = track.errorCode;
        await _deleteIfExists(tempPath);
        if (track.status == DownloadStatus.cancelled) return track;
        if (!_retriableErrors.contains(track.errorCode)) return track;
      }
    }

    // 2) Device manifest: audio-only tracks first. If the video has no
    //    audio-only track (common for old/odd uploads) the smallest muxed
    //    track is used as a last resort and its audio is extracted by the
    //    backend. That is what makes "MP3" available for those videos.
    if (videoId != null) {
      try {
        final manifest = await _ytc.videos.streamsClient
            .getManifest(videoId)
            .timeout(const Duration(seconds: 20));
        final candidates = _mp3Candidates(manifest, task.formatId);
        onStep(const DownloadStep('resolving', 'Selecting audio track...'));
        _log('MP3: device manifest -> ${candidates.length} candidates');

        for (final candidate in candidates) {
          if (!_activeDownloads.containsKey(task.id)) {
            return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
          }
          final isVideo = _streamHasVideo(candidate);
          if (!_streamHasAudio(candidate)) continue;
          final ext = isVideo ? 'mp4' : _getExtension(candidate);
          final tempPath = _tempSourcePath(task, 'audio.$ext');
          tempFiles.add(tempPath);

          onStep(DownloadStep('downloading',
              isVideo ? 'Downloading source track...' : 'Downloading audio track...'));
          final track = await _downloadViaHttpClient(
            url: candidate.url,
            filePath: tempPath,
            totalBytes: candidate.size.totalBytes,
            onProgress: _scaledProgressInRange(onProgress, 0.0, 0.5),
            task: task,
            headers: _headersFor(candidate.url),
            responseTimeout: const Duration(seconds: 60),
            operation: 'mp3_source',
          );
          if (track.status != DownloadStatus.completed) {
            lastError = track.errorCode;
            await _deleteIfExists(tempPath);
            if (track.status == DownloadStatus.cancelled) return track;
            if (!_retriableErrors.contains(track.errorCode)) return track;
            continue;
          }

          final converted = await _convertToMp3(
            task: task,
            tempPath: tempPath,
            ext: ext,
            filePath: filePath,
            onProgress: onProgress,
            onStep: onStep,
            sw: sw,
          );
          if (converted.status == DownloadStatus.completed) return converted;
          // The bytes were fine but ffmpeg/the backend failed. Another track
          // would upload the same content again and fail identically.
          return converted;
        }
      } catch (e) {
        _log('MP3: device path failed: $e');
        lastError = e is TimeoutException
            ? DownloadErrorType.streamsTimeout
            : DownloadErrorType.streamsFailed;
      }
    }

    // 3) Sources that are not YouTube have no device manifest: the backend is
    //    the only one that can resolve and convert them. It may also succeed
    //    for YouTube when it is not blocked (development, other hosts).
    final canAskServer = task.url.isNotEmpty || directRaw.isNotEmpty;
    if (canAskServer) {
      final converted = await _downloadMp3Converted(
        task: task,
        dir: dir,
        onProgress: onProgress,
        onStep: onStep,
        sw: sw,
      );
      if (converted.status == DownloadStatus.completed) return converted;
      // The device error is the one that describes the user's reality: the
      // server's "extractor unavailable" is a host limitation, not the cause.
      lastError ??= converted.errorCode;
    }

    await _cleanupTempFiles(tempFiles);
    _log('MP3: no real MP3 produced (device=$lastError)');
    return task.copyWith(
      status: 'failed',
      error: 'No real MP3 could be produced (last error: $lastError)',
      errorCode:
          (lastError ?? DownloadErrorType.conversionFailed).name,
    );
  }

  /// Audio-only streams by bitrate, then the smallest muxed stream. The
  /// muxed fallback exists only because some videos publish no audio-only
  /// row at all; it is never used when a real audio track is downloadable.
  List<StreamInfo> _mp3Candidates(StreamManifest manifest, String formatId) {
    final result = <StreamInfo>[];
    final tag = int.tryParse(formatId.replaceAll('__mp3', ''));
    final audio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    if (tag != null) {
      result.addAll(audio.where((s) => s.tag == tag));
    }
    for (final s in audio) {
      if (!result.contains(s)) result.add(s);
    }
    final muxed = manifest.muxed.toList()
      ..sort((a, b) => a.videoResolution.height.compareTo(b.videoResolution.height));
    if (tag != null) {
      result.addAll(muxed.where((s) => s.tag == tag));
    }
    for (final s in muxed) {
      if (!result.contains(s)) result.add(s);
    }
    return result;
  }

  Future<DownloadTask> _convertToMp3({
    required DownloadTask task,
    required String tempPath,
    required String ext,
    required String filePath,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) async {
    onStep(const DownloadStep('processing', 'Converting to MP3...'));
    final uri = Uri.parse(ApiConfig.convertAudioUrl).replace(queryParameters: {
      if (task.title.isNotEmpty) 'title': task.title,
      if ((task.source ?? '').isNotEmpty) 'artist': task.source!,
      if ((task.thumbnail ?? '').isNotEmpty) 'cover': task.thumbnail!,
      'ext': ext,
    });
    final converted = await _uploadAndSave(
      uri: uri,
      parts: [_UploadPart('audio', tempPath, 'audio.$ext')],
      outputPath: filePath,
      task: task,
      onProgress: _scaledProgressInRange(onProgress, 0.5, 0.5),
      responseTimeout: const Duration(minutes: 5),
      operation: 'convert_audio',
    );
    await _deleteIfExists(tempPath);
    if (converted.status == DownloadStatus.completed) {
      _log('MP3: real mp3 saved ${converted.filePath} '
          '(${converted.bytesDownloaded} bytes) in ${sw.elapsedMilliseconds}ms');
    }
    return converted;
  }

  /// Wraps [onProgress] so a phase that feeds into a later one reports its own
  /// real share of the bar (no fake/simulated progress).
  static Function(double, int) _scaledProgressInRange(
    Function(double, int) onProgress,
    double start,
    double span,
  ) =>
      (p, b) =>
          onProgress(start + p.clamp(0.0, 1.0) * span, b);

  /// Real MP3 from a provider URL, resolved and converted by the backend.
  Future<DownloadTask> _downloadMp3Converted({
    required DownloadTask task,
    required String dir,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) async {
    final safeTitle = _sanitizeFilename(task.title);
    final filePath = '$dir/$safeTitle.mp3';

    final params = <String, String>{
      // yt-dlp resolves the track from the provider URL (fresh, correctly
      // signed URLs); the direct CDN URL is only used when there is no format
      // id to ask for.
      if (task.url.isNotEmpty) 'url': task.url,
      // A synthetic MP3 menu entry carries the source stream tag with a
      // __mp3 suffix; the backend expects the real provider format id.
      if (task.formatId.trim().isNotEmpty)
        'format_id': task.formatId.trim().replaceAll('__mp3', ''),
      if (task.formatId.trim().isEmpty && (task.directUrl ?? '').isNotEmpty)
        'direct': task.directUrl!,
      if (task.title.isNotEmpty) 'title': task.title,
      if ((task.source ?? '').isNotEmpty) 'artist': task.source!,
      if ((task.thumbnail ?? '').isNotEmpty) 'cover': task.thumbnail!,
    };
    final uri = Uri.parse(ApiConfig.convertAudioUrl).replace(queryParameters: params);

    _log('MP3: server conversion -> ${uri.path} params=${params.keys.join(",")}');
    onStep(const DownloadStep('processing', 'Converting to MP3...'));

    // The first byte only arrives once the server has downloaded and encoded
    // the track, so the response timeout has to cover the whole conversion.
    final result = await _downloadViaHttpClient(
      url: uri,
      filePath: filePath,
      totalBytes: 0,
      onProgress: onProgress,
      task: task,
      headers: _headersFor(uri),
      responseTimeout: const Duration(minutes: 5),
      operation: 'convert_audio_server',
    );

    if (result.status == DownloadStatus.completed) {
      _log('MP3: saved ${result.filePath} (${result.bytesDownloaded} bytes)');
    }
    return result;
  }

  /// Video-only tracks (the "1080p · sin audio" rows) need a muxer, and the
  /// device has none: the local `ffmpeg` merge always failed and the file was
  /// saved muted. The backend merges the chosen video track with the best
  /// audio track (`yt-dlp -f <tag>+bestaudio`). A pipe cannot carry mp4, so
  /// yt-dlp writes Matroska and the file is saved as `.mkv`.
  Future<DownloadTask> _downloadMergedVideo({
    required DownloadTask task,
    required String dir,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) {
    _log('MERGE: backend muxes ${task.formatId}+bestaudio (no ffmpeg on device)');
    onStep(const DownloadStep('processing', 'Muxing video + audio on the server...'));
    return _downloadDirect(
      task: task,
      dir: dir,
      onProgress: onProgress,
      onStep: onStep,
      sw: sw,
      formatIdOverride: '${task.formatId.trim()}+bestaudio',
      extOverride: 'mkv',
    );
  }

  Future<DownloadTask> startDownload({
    required DownloadTask task,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
  }) async {
    final sw = Stopwatch()..start();
    _log('===== START id=${task.id} =====');
    _log('original URL = ${task.url}');
    _log('formatId=${task.formatId}');
    _log('title=${task.title}');
    _log('downloadPath=${StorageService.instance.downloadPath}');

    _activeDownloads[task.id] = true;

    try {
      onStep(const DownloadStep('preparing', 'Checking storage...'));
      _log('STEP 0: Storage write test...');

      final dir = StorageService.instance.downloadPath;
      if (dir.isEmpty) {
        _log('STEP 0 FAILED: downloadPath is empty');
        return task.copyWith(status: 'failed', error: 'Download directory not configured', errorCode: 'storageNotConfigured');
      }
      _log('STEP 0: target directory = $dir');

      final dirObj = Directory(dir);
      if (!await dirObj.exists()) {
        _log('STEP 0: Directory does not exist, creating...');
        await dirObj.create(recursive: true);
      }

      final writable = await StorageService.instance.testDirectoryWritable(dir);
      if (!writable) {
        _log('STEP 0 FAILED: Directory NOT writable: $dir');
        return task.copyWith(
          status: 'failed',
          error: 'Cannot write to directory: $dir',
          errorCode: 'storageNotWritable',
        );
      }
      _log('STEP 0 OK: directory writable = true (${sw.elapsedMilliseconds}ms)');

      // Refuse before downloading 300 MB into a full disk. When the exact
      // size is unknown only the write failure can detect it.
      final expected = task.totalBytes ?? 0;
      if (expected > 0) {
        final available = await StorageService.instance.availableBytes(dir);
        const margin = 64 * 1024 * 1024;
        if (available > 0 && available < expected + margin) {
          _log('STEP 0 FAILED: need ${expected + margin} bytes, free=$available');
          return task.copyWith(
            status: 'failed',
            error: 'Not enough free storage',
            errorCode: DownloadErrorType.insufficientSpace.name,
          );
        }
      }

      // MP3: a real MP3 or a typed failure. The device downloads the track
      // and the backend encodes it (see _downloadAudioAsMp3). M4A/WebM
      // selections use the normal audio-only track path below, so the
      // extension shown in the UI is the extension actually saved.
      if (wantsMp3(task) &&
          (task.url.isNotEmpty || (task.directUrl ?? '').isNotEmpty)) {
        final mp3 = await _downloadAudioAsMp3(
          task: task,
          dir: dir,
          onProgress: onProgress,
          onStep: onStep,
          sw: sw,
        );
        // Never continue into a path that would save the raw m4a/webm under
        // an MP3 task: that is the false "MP3" this flow replaces.
        return mp3;
      }

      final sanitizedUrl = LocalExtractionService.sanitizeUrl(task.url);
      final videoId = _parseVideoId(sanitizedUrl);

      // Video-only tracks must be muxed. For YouTube the backend relay is
      // known to be unable to resolve the media from its host, so the device
      // goes straight to its own tracks + server mux. Other providers still
      // use the server-side merge when they offer it. A muted video is never
      // saved as a completed download.
      DownloadTask? mergeError;
      if (task.mediaType == DownloadMediaType.video &&
          task.hasVideo &&
          !task.hasAudio &&
          task.formatId.trim().isNotEmpty &&
          videoId == null) {
        final merged = await _downloadMergedVideo(
          task: task,
          dir: dir,
          onProgress: onProgress,
          onStep: onStep,
          sw: sw,
        );
        if (merged.status == DownloadStatus.completed) return merged;
        mergeError = merged;
        _log('Backend merge failed (${merged.errorCode}); '
            'falling back to device tracks + server mux');
        await _deleteIfExists(merged.filePath);
      }

      DownloadTask? directResult;
      // A video-only direct URL is not a valid download: saving it as-is is
      // the muted-video false success. Those tasks go through the mux path.
      final needsMux = task.mediaType == DownloadMediaType.video &&
          task.hasVideo &&
          !task.hasAudio;
      if (task.directUrl != null &&
          task.directUrl!.isNotEmpty &&
          !needsMux) {
        _log('DIRECT branch: using backend-provided direct URL');
        directResult = await _downloadDirect(
          task: task,
          dir: dir,
          onProgress: onProgress,
          onStep: onStep,
          sw: sw,
        );
        // Recoverable backend failures (403, 5xx, network) fall through to
        // the device stream path instead of failing the whole download.
        if (!_retriableErrors.contains(directResult.errorCode)) return directResult;
        _log('DIRECT failed (${directResult.errorCode}); '
            'falling back to device stream manifest');
      }

      onStep(const DownloadStep('resolving', 'Parsing video ID...'));
      _log('STEP 1: Parsing video ID...');
      if (videoId == null) {
        _log('STEP 1 FAILED: Could not parse video ID from: $sanitizedUrl');
        // Not a YouTube URL (device streams are YouTube-only): surface the
        // real backend error instead of a misleading "invalid url".
        if (mergeError != null) return mergeError;
        if (directResult != null) return directResult;
        return task.copyWith(
          status: 'failed',
          error: 'Invalid YouTube URL',
          errorCode: 'invalidUrl',
        );
      }
      _log('STEP 1 OK: parsed video ID = $videoId (${sw.elapsedMilliseconds}ms)');

      onStep(const DownloadStep('resolving', 'Fetching streams...'));
      _log('STEP 2: Fetching stream manifest...');

      StreamManifest manifest;
      try {
        manifest = await _ytc.videos.streamsClient.getManifest(videoId).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            _log('STEP 2 TIMEOUT: getManifest exceeded 30s');
            throw TimeoutException('Stream manifest fetch timed out (30s)');
          },
        );
      } catch (e) {
        _log('STEP 2 FAILED: $e');
        final isTimeout = e is TimeoutException;
        // The device could not even fetch the manifest — the backend relay
        // may still succeed (it re-extracts fresh URLs server-side).
        if (task.formatId.trim().isNotEmpty) {
          _log('FALLBACK: manifest unavailable, retrying via backend relay');
          try {
            return await _downloadDirect(
              task: task,
              dir: dir,
              onProgress: onProgress,
              onStep: onStep,
              sw: sw,
            );
          } catch (re) {
            _log('RELAY exception: $re');
          }
        }
        return task.copyWith(
          status: 'failed',
          error: isTimeout ? 'Streams fetch timed out' : 'Failed to fetch streams',
          errorCode: isTimeout ? 'streamsTimeout' : 'streamsFailed',
        );
      }

      _log('STEP 2 OK: muxed=${manifest.muxed.length} videoOnly=${manifest.videoOnly.length} audioOnly=${manifest.audioOnly.length} (${sw.elapsedMilliseconds}ms)');

      for (final s in manifest.muxed) {
        _log('  stream: tag=${s.tag} type=Muxed container=${s.container.name} bitrate=${s.bitrate.bitsPerSecond}bps resolution=${s.videoResolution} size=${s.size.totalBytes}');
      }
      for (final s in manifest.videoOnly) {
        _log('  stream: tag=${s.tag} type=VideoOnly container=${s.container.name} bitrate=${s.bitrate.bitsPerSecond}bps resolution=${s.videoResolution} size=${s.size.totalBytes}');
      }
      for (final s in manifest.audioOnly) {
        _log('  stream: tag=${s.tag} type=AudioOnly container=${s.container.name} bitrate=${s.bitrate.bitsPerSecond}bps size=${s.size.totalBytes}');
      }

      onStep(const DownloadStep('resolving', 'Selecting stream...'));
      _log('STEP 3: Building candidate list...');

      _log('[DOWNLOAD] requestedMediaType=${task.mediaType.name}');
      final candidates = _buildCandidateList(manifest, task.formatId, task.mediaType);
      _log('STEP 3: ${candidates.length} candidates');

      if (candidates.isEmpty) {
        _log('STEP 3 FAILED: No streams available');
        return task.copyWith(status: 'failed', error: 'No downloadable streams', errorCode: 'noStreams');
      }

      for (final c in candidates) {
        _log('  candidate: tag=${c.stream.tag} type=${c.stream.runtimeType} mux=${c.needsMux} container=${c.stream.container.name}');
      }

      onStep(const DownloadStep('connecting', 'Connecting to server...'));

      for (int i = 0; i < candidates.length; i++) {
        if (!_activeDownloads.containsKey(task.id)) {
          return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
        }

        final candidate = candidates[i];
        _log('STEP 4: Trying candidate ${i + 1}/${candidates.length}: tag=${candidate.stream.tag}');

        if (task.mediaType == DownloadMediaType.audio) {
          final hasVid = _streamHasVideo(candidate.stream);
          final hasAud = _streamHasAudio(candidate.stream);
          _log('[DOWNLOAD] selectedStream=${candidate.stream.tag} hasVideo=$hasVid hasAudio=$hasAud');
          if (hasVid) {
            _log('[DOWNLOAD][ERROR] Selected stream is not audio-only, skipping tag=${candidate.stream.tag}');
            continue;
          }
        }

        final streamUrl = candidate.stream.url;

        if (candidate.needsMux && candidate.stream is VideoOnlyStreamInfo) {
          final muxResult = await _downloadWithMuxing(
            task: task,
            videoOnlyStream: candidate.stream as VideoOnlyStreamInfo,
            manifest: manifest,
            onProgress: onProgress,
            onStep: onStep,
            sw: sw,
          );
          if (muxResult.status == DownloadStatus.completed) return muxResult;
          if (muxResult.status == DownloadStatus.cancelled) return muxResult;
          if (muxResult.errorCode != DownloadErrorType.http403) return muxResult;
          _log('  MUX candidate failed with 403, trying next...');
          continue;
        }

        final safeTitle = _sanitizeFilename(task.title);
        final ext = task.mediaType == DownloadMediaType.audio
            ? _getExtension(candidate.stream)
            : _getVideoExtension(candidate.stream);
        final filePath = '$dir/$safeTitle.$ext';
        final totalBytes = candidate.stream.size.totalBytes;
        _log('STEP 5: filePath=$filePath ext=$ext contentType=${candidate.stream.codec.mimeType} size=$totalBytes');

        onStep(const DownloadStep('downloading', 'Downloading...'));
        _log('STEP 5: Starting HTTP download for tag=${candidate.stream.tag}...');

        final result = await _downloadViaHttpClient(
          url: streamUrl,
          filePath: filePath,
          totalBytes: totalBytes,
          onProgress: onProgress,
          task: task,
        );

        if (result.status == DownloadStatus.completed) {
          sw.stop();
          _log('===== COMPLETED id=${task.id} =====');
          _log('file=${result.filePath} size=${result.bytesDownloaded} (${(result.bytesDownloaded / 1024 / 1024).toStringAsFixed(1)} MB) time=${sw.elapsedMilliseconds}ms');
          if (task.mediaType == DownloadMediaType.audio) {
            final file = File(result.filePath!);
            _log('[AUDIO] outputPath=${result.filePath}');
            _log('[AUDIO] exists=${await file.exists()}');
            _log('[AUDIO] size=${await file.length()}');
            _log('[AUDIO] extension=${result.filePath!.split('.').last}');
            _log('[AUDIO] completed=true');
          }
          return result;
        }

        if (result.status == DownloadStatus.cancelled) {
          sw.stop();
          return result;
        }

        if (result.errorCode == DownloadErrorType.http403) {
          _log('  403 on tag=${candidate.stream.tag}, trying next candidate...');
          try {
            await File(filePath).delete();
          } catch (_) {}
          continue;
        }

        sw.stop();
        _log('===== FAILED id=${task.id} =====');
        _log('error=${result.error} errorCode=${result.errorCode}');
        return result;
      }

      _log('===== ALL CANDIDATES EXHAUSTED id=${task.id} =====');
      if (task.mediaType == DownloadMediaType.audio) {
        // The relay would have to download a muxed video to return audio,
        // and could save video bytes under a .m4a name. Fail honestly.
        sw.stop();
        return task.copyWith(
          status: 'failed',
          error: 'No audio-only track is available for this video',
          errorCode: DownloadErrorType.noStreams.name,
        );
      }
      // Last line of defence: relay the requested format through the
      // backend /api/fetch (yt-dlp re-extracts fresh, working URLs
      // server-side) instead of forcing a generic 403 failure.
      final relayFormat = task.formatId.trim().isNotEmpty
          ? task.formatId.trim()
          : (candidates.isNotEmpty
              ? candidates.first.stream.tag.toString()
              : '');
      if (relayFormat.isNotEmpty && !needsMux) {
        _log('FALLBACK: retrying via backend relay format=$relayFormat');
        try {
          final relay = await _downloadDirect(
            task: task,
            dir: dir,
            onProgress: onProgress,
            onStep: onStep,
            sw: sw,
            formatIdOverride: relayFormat,
          );
          sw.stop();
          return relay;
        } catch (re) {
          _log('RELAY exception: $re');
        }
      }
      sw.stop();
      _log('===== FAILED id=${task.id} =====');
      return task.copyWith(status: 'failed', error: 'All streams returned errors', errorCode: 'http403');
    } catch (e, st) {
      _log('[ERROR] EXCEPTION: $e');
      _log('[ERROR] STACK: $st');
      return task.copyWith(status: 'failed', error: 'Download failed', errorCode: 'generic');
    } finally {
      _activeDownloads.remove(task.id);
    }
  }

  List<_CandidateStream> _buildCandidateList(StreamManifest manifest, String formatId, DownloadMediaType mediaType) {
    final candidates = <_CandidateStream>[];
    final formatTag = int.tryParse(formatId);

    _log('[DOWNLOAD] _buildCandidateList mediaType=${mediaType.name} formatId=$formatId');

    if (mediaType == DownloadMediaType.audio) {
      _log('[AUDIO] Building audio-only candidate list');
      final sortedAudio = List<AudioOnlyStreamInfo>.from(manifest.audioOnly)
        ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

      if (formatTag != null) {
        final exact = manifest.audioOnly.where((s) => s.tag == formatTag).toList();
        if (exact.isNotEmpty) {
          for (final s in exact) {
            candidates.add(_CandidateStream(s, false));
          }
          for (final s in sortedAudio) {
            if (s.tag != formatTag) candidates.add(_CandidateStream(s, false));
          }
          return candidates;
        }
      }

      for (final s in sortedAudio) {
        candidates.add(_CandidateStream(s, false));
      }
      return candidates;
    }

    final sortedMuxed = List<MuxedStreamInfo>.from(manifest.muxed)
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    final sortedVideoOnly = List<VideoOnlyStreamInfo>.from(manifest.videoOnly)
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    final sortedAudio = List<AudioOnlyStreamInfo>.from(manifest.audioOnly)
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
    final hasAudioStreams = sortedAudio.isNotEmpty;

    if (formatTag != null) {
      final exact = manifest.streams.where((s) => s.tag == formatTag).toList();
      if (exact.isNotEmpty) {
        final stream = exact.first;

        if (stream is MuxedStreamInfo) {
          candidates.add(_CandidateStream(stream, false));
          for (final s in sortedMuxed) {
            if (s.tag != formatTag) candidates.add(_CandidateStream(s, false));
          }
          for (final s in sortedVideoOnly) {
            candidates.add(_CandidateStream(s, hasAudioStreams));
          }
          for (final s in sortedAudio) {
            candidates.add(_CandidateStream(s, false));
          }
        } else if (stream is VideoOnlyStreamInfo) {
          candidates.add(_CandidateStream(stream, hasAudioStreams));
          for (final s in sortedMuxed) {
            candidates.add(_CandidateStream(s, false));
          }
          for (final s in sortedVideoOnly) {
            if (s.tag != formatTag) candidates.add(_CandidateStream(s, hasAudioStreams));
          }
          for (final s in sortedAudio) {
            candidates.add(_CandidateStream(s, false));
          }
        } else if (stream is AudioOnlyStreamInfo) {
          candidates.add(_CandidateStream(stream, false));
          for (final s in sortedAudio) {
            if (s.tag != formatTag) candidates.add(_CandidateStream(s, false));
          }
          for (final s in sortedMuxed) {
            candidates.add(_CandidateStream(s, false));
          }
          for (final s in sortedVideoOnly) {
            candidates.add(_CandidateStream(s, hasAudioStreams));
          }
        } else {
          candidates.add(_CandidateStream(stream, stream is VideoOnlyStreamInfo));
        }
        return candidates;
      }
    }

    for (final s in sortedMuxed) {
      candidates.add(_CandidateStream(s, false));
    }
    for (final s in sortedVideoOnly) {
      candidates.add(_CandidateStream(s, hasAudioStreams));
    }
    for (final s in sortedAudio) {
      candidates.add(_CandidateStream(s, false));
    }

    return candidates;
  }

  /// Video-only track + audio track → one real file with both streams.
  ///
  /// The old path stopped after the video track and marked the download as
  /// completed, so the user got a muted video named like a normal download.
  /// An Android app cannot run ffmpeg, so both tracks (downloaded here, with
  /// the phone's own signed URLs) are uploaded to the backend and muxed with
  /// `-c copy`; the response is the actual container (mp4, or mkv when the
  /// codecs are not mp4-compatible).
  Future<DownloadTask> _downloadWithMuxing({
    required DownloadTask task,
    required VideoOnlyStreamInfo videoOnlyStream,
    required StreamManifest manifest,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) async {
    final audioStreams = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

    if (audioStreams.isEmpty) {
      _log('MUX FAILED: No audio stream available');
      return task.copyWith(status: 'failed', error: 'No audio stream', errorCode: 'muxNoAudio');
    }

    final dir = StorageService.instance.downloadPath;
    final safeTitle = _sanitizeFilename(task.title);
    final videoExt = videoOnlyStream.container.name;
    final audioStream = audioStreams.first;
    final audioExt = _getExtension(audioStream);
    final videoTempPath = _tempSourcePath(task, 'video.$videoExt');
    final audioTempPath = _tempSourcePath(task, 'audio.$audioExt');

    try {
      final totalVideoBytes = videoOnlyStream.size.totalBytes;
      _log('MUX: video tag=${videoOnlyStream.tag} '
          'size=$totalVideoBytes (${(totalVideoBytes / 1024 / 1024).toStringAsFixed(1)} MB)');

      onStep(const DownloadStep('downloading', 'Downloading video track...'));
      final videoResult = await _downloadViaHttpClient(
        url: videoOnlyStream.url,
        filePath: videoTempPath,
        totalBytes: totalVideoBytes,
        onProgress: _scaledProgressInRange(onProgress, 0.0, 0.45),
        task: task,
        headers: _headersFor(videoOnlyStream.url),
      );
      if (videoResult.status != DownloadStatus.completed) return videoResult;

      if (!_activeDownloads.containsKey(task.id)) {
        return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
      }

      onStep(const DownloadStep('downloading', 'Downloading audio track...'));
      final audioResult = await _downloadViaHttpClient(
        url: audioStream.url,
        filePath: audioTempPath,
        totalBytes: audioStream.size.totalBytes,
        onProgress: _scaledProgressInRange(onProgress, 0.45, 0.45),
        task: task,
        headers: _headersFor(audioStream.url),
      );
      if (audioResult.status != DownloadStatus.completed) {
        await _cleanupTempFiles([videoTempPath]);
        return audioResult;
      }

      onStep(const DownloadStep('processing', 'Muxing video + audio on the server...'));
      final merged = await _uploadAndSave(
        uri: Uri.parse(ApiConfig.mergeUrl).replace(queryParameters: {
          if (task.title.isNotEmpty) 'title': task.title,
        }),
        parts: [
          _UploadPart('video', videoTempPath, 'video.$videoExt'),
          _UploadPart('audio', audioTempPath, 'audio.$audioExt'),
        ],
        // The extension is decided by the server (mp4, or mkv when needed).
        outputPath: '$dir/$safeTitle.mp4',
        task: task,
        onProgress: _scaledProgressInRange(onProgress, 0.9, 0.1),
        responseTimeout: const Duration(minutes: 10),
        operation: 'merge',
      );

      await _cleanupTempFiles([videoTempPath, audioTempPath]);

      if (merged.status == DownloadStatus.completed) {
        final format = merged.filePath?.split('.').last;
        _log('MUX DONE: ${merged.filePath} '
            '(${merged.bytesDownloaded} bytes, $format) in ${sw.elapsedMilliseconds}ms');
      }
      return merged;
    } catch (e, st) {
      _log('[ERROR] MUX EXCEPTION: $e');
      _log('[ERROR] MUX STACK: $st');
      await _cleanupTempFiles([videoTempPath, audioTempPath]);
      return task.copyWith(
        status: 'failed',
        error: 'Merge failed (${e.runtimeType})',
        errorCode: DownloadErrorType.mergeFailed.name,
      );
    }
  }

  /// Posts one or two local files to the backend and streams the processed
  /// result to [outputPath]. Progress is the real number of bytes sent.
  Future<DownloadTask> _uploadAndSave({
    required Uri uri,
    required List<_UploadPart> parts,
    required String outputPath,
    required DownloadTask task,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Duration responseTimeout,
    required String operation,
  }) async {
    final sw = Stopwatch()..start();
    var totalBytes = 0;
    var sent = 0;
    var producedPath = outputPath;
    final lengths = <_UploadPart, int>{};
    try {
      for (final part in parts) {
        final length = await File(part.path).length();
        if (length <= 0) {
          return task.copyWith(
            status: 'failed',
            error: 'Empty upload part (${part.field})',
            errorCode: DownloadErrorType.fileEmpty.name,
          );
        }
        lengths[part] = length;
        totalBytes += length;
      }

      final request = http.MultipartRequest('POST', uri);
      request.headers.addAll(ApiConfig.authHeaders);
      for (final part in parts) {
        final length = lengths[part]!;
        final progressStream = File(part.path)
            .openRead()
            .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (data, sink) {
            sent += data.length;
            if (totalBytes > 0) {
              onProgress(sent / totalBytes, sent);
            }
            sink.add(data);
          },
        ));
        request.files.add(http.MultipartFile(
          part.field,
          progressStream,
          length,
          filename: part.filename,
        ));
      }

      _log('UPLOAD $operation: host=${uri.host} '
          'parts=${parts.map((p) => p.field).join(",")} bytes=$totalBytes');

      final streamed = await request.send().timeout(responseTimeout);
      if (streamed.statusCode != 200) {
        final body = await streamed.stream.bytesToString();
        final info = parseBackendError(streamed.statusCode, body);
        final code = errorTypeOf(info);
        _log('UPLOAD FAILED $operation: '
            '${describeBackendError(info, operation: operation)} '
            'time=${sw.elapsedMilliseconds}ms');
        return task.copyWith(
          status: 'failed',
          error: describeBackendError(info, operation: operation),
          errorCode: code.name,
        );
      }

      final file = File(outputPath);
      producedPath = outputPath;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk
            in streamed.stream.timeout(const Duration(seconds: 120))) {
          if (!_activeDownloads.containsKey(task.id)) {
            await sink.close();
            await _deleteIfExists(outputPath);
            return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
          }
          sink.add(chunk);
          received += chunk.length;
        }
      } finally {
        await sink.close();
      }

      // The mux may fall back to Matroska when the codecs do not fit MP4;
      // the server says which container it produced, the file must match it.
      var finalPath = outputPath;
      final announced = streamed.headers['x-vibegrab-format']?.trim();
      if (announced != null && announced.isNotEmpty) {
        final wanted =
            outputPath.replaceFirst(RegExp(r'\.[^./\\]+$'), '.$announced');
        if (wanted != outputPath) {
          try {
            await file.rename(wanted);
            finalPath = wanted;
            producedPath = wanted;
          } catch (e) {
            _log('UPLOAD: could not rename to .$announced: $e');
          }
        }
      }

      if (received == 0 || !await File(finalPath).exists()) {
        await _deleteIfExists(finalPath);
        return task.copyWith(
          status: 'failed',
          error: 'The server returned an empty file',
          errorCode: DownloadErrorType.fileEmpty.name,
        );
      }

      // Size alone is not proof: a proxy error page or a mismatched container
      // would also be "non-empty". Check the real signature of what was
      // written before calling the download complete.
      final outExt = finalPath.contains('.')
          ? finalPath.substring(finalPath.lastIndexOf('.') + 1).toLowerCase()
          : '';
      if (!await _matchesContainer(finalPath, outExt)) {
        _log('UPLOAD: produced file does not match .$outExt');
        await _deleteIfExists(finalPath);
        return task.copyWith(
          status: 'failed',
          error: 'The server produced a file that is not a valid .$outExt '
              'container',
          errorCode: (operation.startsWith('merge')
                  ? DownloadErrorType.mergeFailed
                  : DownloadErrorType.conversionFailed)
              .name,
        );
      }

      onProgress(1.0, received);
      _log('UPLOAD DONE $operation: $finalPath ($received bytes) '
          'in ${sw.elapsedMilliseconds}ms');
      return task.copyWith(
        status: 'completed',
        progress: 1.0,
        bytesDownloaded: received,
        totalBytes: received,
        filePath: finalPath,
      );
    } on TimeoutException {
      _log('UPLOAD TIMEOUT $operation after ${sw.elapsedMilliseconds}ms');
      await _deleteIfExists(producedPath);
      return task.copyWith(
        status: 'failed',
        error: 'Server timed out during $operation',
        errorCode: DownloadErrorType.serverTimeout.name,
      );
    } catch (e) {
      _log('UPLOAD ERROR $operation: ${e.runtimeType} after ${sw.elapsedMilliseconds}ms');
      // A socket can die after the server started streaming the result: the
      // half-written MP3/video would show up in the library as a finished
      // download and look like a second copy. Remove it.
      await _deleteIfExists(producedPath);
      return task.copyWith(
        status: 'failed',
        error: 'Upload failed (${e.runtimeType})',
        errorCode: DownloadErrorType.connectionFailed.name,
      );
    }
  }

  /// Checks the first bytes of a produced file against the container the task
  /// promised. A non-empty file is not enough: an error page or a different
  /// container would otherwise be reported as a successful download.
  Future<bool> _matchesContainer(String path, String ext) async {
    try {
      final raf = await File(path).open();
      try {
        final head = await raf.read(12);
        return matchesContainerHeader(head, ext);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<DownloadTask> _downloadViaHttpClient({
    required Uri url,
    required String filePath,
    required int totalBytes,
    required Function(double progress, int bytesDownloaded) onProgress,
    required DownloadTask task,
    Map<String, String> headers = _youTubeHeaders,
    Duration responseTimeout = const Duration(seconds: 30),
    String operation = 'download',
  }) async {
    _log('HTTP GET [$operation]: ${url.host}${url.path.substring(0, url.path.length.clamp(0, 40))}...');
    final sw = Stopwatch()..start();
    final partPath = _partialPathFor(filePath, task.id, url);
    var offset = 0;

    try {
      final part = File(partPath);
      if (await part.exists()) offset = await part.length();
      // Without a known total there is no way to prove the old bytes belong
      // to this stream. Starting clean is cheaper than a corrupt media file.
      if (offset <= 0 || totalBytes <= 0 || offset >= totalBytes) {
        if (offset > 0) await _deleteIfExists(partPath);
        offset = 0;
      } else {
        _log('HTTP: resuming from $offset bytes');
      }
    } catch (_) {
      offset = 0;
    }

    const maxAttempts = 2;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final httpClient = HttpClient();
      httpClient.connectionTimeout = const Duration(seconds: 30);
      httpClient.idleTimeout = const Duration(seconds: 30);
      IOSink? sink;

      try {
        _log('Creating HTTP request...');
        final request = await httpClient.getUrl(url).timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            _log('HTTP: getConnection timed out (30s)');
            throw TimeoutException('Connection timed out');
          },
        );

        for (final entry in headers.entries) {
          request.headers.set(entry.key, entry.value);
        }
        // Only ask for a range when there is something to append to. The old
        // unconditional "bytes=0-" made every first request a 206 and some
        // CDNs answer it more slowly than a plain GET.
        if (offset > 0) {
          request.headers.set('Range', 'bytes=$offset-');
        }
        request.followRedirects = true;
        request.maxRedirects = 10;

        _log('HTTP: Sending request${offset > 0 ? ' (resume at $offset)' : ''}...');
        final response = await request.close().timeout(
          responseTimeout,
          onTimeout: () {
            _log('HTTP: getResponse timed out (${responseTimeout.inSeconds}s)');
            throw TimeoutException('Server response timed out');
          },
        );

        _log('HTTP: status=${response.statusCode} contentLength=${response.contentLength} contentType=${response.headers.contentType}');

        if (response.statusCode != 200 && response.statusCode != 206) {
          // A transient 5xx is worth one retry; a 403/404 is not and must go
          // back to the candidate loop so another route can be tried.
          final transient = response.statusCode == 408 ||
              response.statusCode == 429 ||
              response.statusCode >= 500;
          if (transient && attempt + 1 < maxAttempts) {
            throw HttpException('HTTP ${response.statusCode}');
          }
          String body = '';
          try {
            body = await response.transform(utf8.decoder).join();
          } catch (_) {}
          final info = parseBackendError(response.statusCode, body);
          final code = errorTypeOf(info);
          final detail = describeBackendError(info, operation: operation);
          _log('HTTP FAILED [$operation]: $detail time=${sw.elapsedMilliseconds}ms');
          return task.copyWith(
            status: 'failed',
            error: detail,
            errorCode: code.name,
          );
        }

        final responseBytes = response.contentLength;
        var resumed = offset;
        if (response.statusCode == 200) {
          // The server ignored Range and is sending the whole file again.
          if (resumed > 0) _log('HTTP: server ignored Range, restarting');
          resumed = 0;
        } else {
          final start = _contentRangeStart(
                response.headers.value('Content-Range'),
              ) ??
              resumed;
          if (start != resumed) {
            // A server that answers a different range than requested would
            // make us append unrelated bytes. Restart cleanly instead.
            if (resumed > 0) await _deleteIfExists(partPath);
            offset = 0;
            throw const HttpException('Unexpected Content-Range');
          }
        }

        final effectiveTotal = responseBytes > 0
            ? resumed + responseBytes
            : (totalBytes > 0 ? totalBytes : 0);
        _log('HTTP: effectiveTotal=$effectiveTotal (${(effectiveTotal / 1024 / 1024).toStringAsFixed(1)} MB)');

        final fileSink = File(partPath)
            .openWrite(mode: resumed > 0 ? FileMode.append : FileMode.write);
        sink = fileSink;
        var bytesDownloaded = resumed;
        var chunkCount = 0;
        var limitBps = 0;
        try {
          final prefs = await SharedPreferences.getInstance();
          limitBps = (prefs.getInt(AppSettingKeys.speedLimitKbps) ?? 0) * 1024;
        } catch (_) {}
        final paceSw = Stopwatch()..start();

        _log('HTTP: Starting SINGLE stream consumption... limitKbps=${limitBps ~/ 1024}');

        await for (final chunk
            in response.timeout(const Duration(seconds: 60))) {
          if (!_activeDownloads.containsKey(task.id)) {
            _log('HTTP: Download cancelled');
            throw const _DownloadCancelledException();
          }

          fileSink.add(chunk);
          bytesDownloaded += chunk.length;
          chunkCount++;
          final transferred = bytesDownloaded - resumed;
          final progress =
              effectiveTotal > 0 ? bytesDownloaded / effectiveTotal : 0.0;
          // A merged/relayed stream has no Content-Length: the estimate can be
          // smaller than the real file, and a progress bar above 100% is worse
          // than one that simply stays full.
          onProgress(progress > 1.0 ? 1.0 : progress, bytesDownloaded);

          if (limitBps > 0) {
            final targetMs = transferred * 1000.0 / limitBps;
            final waitMs = targetMs - paceSw.elapsedMilliseconds;
            if (waitMs >= 20) {
              await Future<void>.delayed(Duration(milliseconds: waitMs.round()));
            }
          }

          if (chunkCount % 50 == 0 || bytesDownloaded == effectiveTotal) {
            _log('HTTP: ${(progress * 100).toStringAsFixed(1)}% (${(bytesDownloaded / 1024 / 1024).toStringAsFixed(1)} MB) chunks=$chunkCount time=${sw.elapsedMilliseconds}ms');
          }
        }

        await fileSink.close();
        sink = null;
        sw.stop();

        _log('HTTP: Stream finished, closing file...');
        final file = File(partPath);
        final verified = await file.exists();
        final size = verified ? await file.length() : 0;
        _log('HTTP DONE: exists=$verified size=$size (${(size / 1024 / 1024).toStringAsFixed(1)} MB) time=${sw.elapsedMilliseconds}ms');

        if (!verified || size == 0) {
          await _deleteIfExists(partPath);
          return task.copyWith(
              status: 'failed',
              error: 'Downloaded file is empty',
              errorCode: 'fileEmpty');
        }

        // The socket closed before the announced length. Keep the bytes for
        // one resume attempt instead of deleting a 90%-complete video.
        if (responseBytes > 0 && size < resumed + responseBytes) {
          throw _IncompleteTransferException(size, resumed + responseBytes);
        }
        if (responseBytes <= 0 &&
            totalBytes > 0 &&
            size < (totalBytes * 0.90).floor()) {
          throw _IncompleteTransferException(
              size, (totalBytes * 0.90).floor());
        }

        // Signature check: a CDN error page saved under .mp4 is not a download.
        final outExt = filePath.contains('.')
            ? filePath.substring(filePath.lastIndexOf('.') + 1).toLowerCase()
            : '';
        if (!await _matchesContainer(partPath, outExt)) {
          await _deleteIfExists(partPath);
          _log('HTTP: downloaded bytes are not a valid .$outExt container');
          return task.copyWith(
            status: 'failed',
            error: 'The downloaded file is not a valid .$outExt container',
            errorCode: DownloadErrorType.unexpectedResponse.name,
          );
        }

        await _deleteIfExists(filePath);
        await file.rename(filePath);
        onProgress(1.0, size);

        return task.copyWith(
          status: 'completed',
          progress: 1.0,
          bytesDownloaded: size,
          totalBytes: size,
          filePath: filePath,
        );
      } catch (e) {
        try {
          await sink?.close();
        } catch (_) {}

        if (e is _DownloadCancelledException ||
            e.toString().contains('cancelled') ||
            e.toString().contains('Cancelled')) {
          // Cancelling means "I don't want these bytes": dropping the .part
          // also prevents them from resuming into a later task.
          await _deleteIfExists(partPath);
          return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
        }

        if (attempt + 1 < maxAttempts && _isRecoverableTransferError(e)) {
          try {
            final size = await File(partPath).length();
            if (size > 0 && totalBytes > 0 && size < totalBytes) {
              offset = size;
              _log('HTTP: retrying from $offset bytes after ${e.runtimeType}');
              continue;
            }
          } catch (_) {
            // The partial file vanished: fall through to cleanup.
          }
        }

        // Never leave a half file with a media extension: players happily
        // open it and stop in the middle.
        await _deleteIfExists(partPath);
        await _deleteIfExists(filePath);
        _log('[ERROR] HTTP EXCEPTION: $e time=${sw.elapsedMilliseconds}ms');
        if (e is TimeoutException) {
          return task.copyWith(
              status: 'failed',
              error: 'Connection timed out',
              errorCode: 'connectionTimeout');
        }
        return task.copyWith(
            status: 'failed',
            error: 'Connection failed',
            errorCode: 'connectionFailed');
      } finally {
        httpClient.close(force: true);
      }
    }

    return task.copyWith(
        status: 'failed',
        error: 'Connection failed',
        errorCode: 'connectionFailed');
  }

  static bool _isRecoverableTransferError(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is _IncompleteTransferException;

  /// Race-free resume name: task plus a stable URL hash. A different format
  /// or CDN route gets a different file, so bytes are never appended to a
  /// stream they did not come from.
  @visibleForTesting
  static String partialPathFor(String filePath, String taskId, Uri url) =>
      _partialPathFor(filePath, taskId, url);

  static String _partialPathFor(String filePath, String taskId, Uri url) {
    final safeId = taskId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    var hash = 0x811c9dc5;
    for (final unit in url.toString().codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '$filePath.$safeId.${hash.toRadixString(16).padLeft(8, '0')}.part';
  }

  @visibleForTesting
  static int? contentRangeStartForTest(String? header) =>
      _contentRangeStart(header);

  static int? _contentRangeStart(String? header) {
    if (header == null) return null;
    final match = RegExp(r'bytes\s+(\d+)-').firstMatch(header);
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<void> cancelDownload(String taskId) async {
    _log('cancelDownload: $taskId');
    _activeDownloads.remove(taskId);
  }

  Future<void> _cleanupTempFiles(List<String> paths) async {
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
          _log('Cleaned: $path');
        }
      } catch (e) {
        _log('Failed to clean $path: $e');
      }
    }
  }

  String _sanitizeFilename(String name) {
    final sanitized = name
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), '_');
    if (sanitized.isEmpty) return 'download';
    return sanitized.substring(0, sanitized.length.clamp(0, 100));
  }

  String? _parseVideoId(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return url.length == 11 &&
              RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(url)
          ? url
          : null;
    }
    final host = uri.host.toLowerCase();
    final isYouTubeHost = host == 'youtube.com' ||
        host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' ||
        host.endsWith('.youtube-nocookie.com') ||
        host == 'youtu.be' ||
        host.endsWith('.youtu.be');
    if (!isYouTubeHost) return null;

    bool valid(String? id) =>
        id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id);

    if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
      if (uri.pathSegments.isNotEmpty && valid(uri.pathSegments.first)) {
        return uri.pathSegments.first;
      }
      return null;
    }
    final vParam = uri.queryParameters['v'];
    if (valid(vParam)) return vParam;

    final segments = uri.pathSegments;
    const kinds = {'shorts', 'embed', 'v', 'vi', 'live'};
    if (segments.length >= 2 && kinds.contains(segments[segments.length - 2])) {
      final id = segments.last;
      if (valid(id)) return id;
    }
    return null;
  }
}
