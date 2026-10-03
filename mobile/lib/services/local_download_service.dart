import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import '../data/models/app_settings.dart';
import '../data/models/download_task.dart';
import '../services/storage_service.dart';
import '../services/local_extraction_service.dart';

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

  static const _directHeaders = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Accept-Language': 'en-US,en;q=0.9',
    'Accept': '*/*',
  };

  Future<DownloadTask> _downloadDirect({
    required DownloadTask task,
    required String dir,
    required Function(double progress, int bytesDownloaded) onProgress,
    required Function(DownloadStep step) onStep,
    required Stopwatch sw,
  }) async {
    final ext = _directExtension(task);
    final safeTitle = _sanitizeFilename(task.title);
    final filePath = '$dir/$safeTitle.$ext';

    final fetchUri = Uri.tryParse(
      '${ApiConfig.baseUrl}/api/fetch'
      '?url=${Uri.encodeQueryComponent(task.url)}'
      '&format_id=${Uri.encodeQueryComponent(task.formatId)}'
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
      headers: _directHeaders,
      responseTimeout: const Duration(seconds: 60),
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

  String _directExtension(DownloadTask task) {
    final fromTask = task.fileExt?.trim();
    if (fromTask != null && fromTask.isNotEmpty && fromTask != 'none') return fromTask;
    final path = Uri.tryParse(task.directUrl!)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot > -1 && dot < path.length - 1) {
      final ext = path.substring(dot + 1).toLowerCase();
      if (ext.length <= 5 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) return ext;
    }
    return 'mp4';
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

      if (task.directUrl != null && task.directUrl!.isNotEmpty) {
        _log('DIRECT branch: using backend-provided direct URL');
        return await _downloadDirect(
          task: task,
          dir: dir,
          onProgress: onProgress,
          onStep: onStep,
          sw: sw,
        );
      }

      onStep(const DownloadStep('resolving', 'Parsing video ID...'));
      _log('STEP 1: Parsing video ID...');
      final sanitizedUrl = LocalExtractionService.sanitizeUrl(task.url);

      final videoId = _parseVideoId(sanitizedUrl);
      if (videoId == null) {
        _log('STEP 1 FAILED: Could not parse video ID from: $sanitizedUrl');
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
        if (streamUrl == null) {
          _log('  SKIP: URL is null');
          continue;
        }

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

      sw.stop();
      _log('===== FAILED id=${task.id} all candidates exhausted =====');
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

    final audioStream = audioStreams.first;
    final dir = StorageService.instance.downloadPath;
    final safeTitle = _sanitizeFilename(task.title);
    final videoExt = videoOnlyStream.container.name;
    final audioExt = audioStream.container.name;
    final videoTempPath = '$dir/${safeTitle}_video_temp.$videoExt';
    final audioTempPath = '$dir/${safeTitle}_video_audio_temp.$audioExt';
    final outputPath = '$dir/${safeTitle}.mp4';

    try {
      final totalVideoBytes = videoOnlyStream.size.totalBytes;
      final totalAudioBytes = audioStream.size.totalBytes;

      _log('MUX: video tag=${videoOnlyStream.tag} size=${totalVideoBytes} (${(totalVideoBytes / 1024 / 1024).toStringAsFixed(1)} MB)');
      _log('MUX: audio tag=${audioStream.tag} size=${totalAudioBytes} (${(totalAudioBytes / 1024 / 1024).toStringAsFixed(1)} MB)');

      onStep(const DownloadStep('downloading', 'Downloading video track...'));
      _log('MUX STEP 1: Downloading video...');

      final videoUrl = videoOnlyStream.url;
      if (videoUrl == null) {
        return task.copyWith(status: 'failed', error: 'Video stream URL not available', errorCode: 'urlNull');
      }

      final videoResult = await _downloadViaHttpClient(
        url: videoUrl,
        filePath: videoTempPath,
        totalBytes: totalVideoBytes,
        onProgress: (p, b) => onProgress(p * 0.5, (b * 0.5).round()),
        task: task,
      );

      if (videoResult.status != DownloadStatus.completed) {
        return videoResult;
      }

      if (!_activeDownloads.containsKey(task.id)) {
        _log('MUX: Cancelled during video download');
        return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
      }

      onStep(const DownloadStep('downloading', 'Downloading audio track...'));
      _log('MUX STEP 2: Downloading audio...');

      final audioUrl = audioStream.url;
      if (audioUrl == null) {
        return task.copyWith(status: 'failed', error: 'Audio stream URL not available', errorCode: 'urlNull');
      }

      final audioResult = await _downloadViaHttpClient(
        url: audioUrl,
        filePath: audioTempPath,
        totalBytes: totalAudioBytes,
        onProgress: (p, b) => onProgress(0.5 + p * 0.5, totalVideoBytes + (b * 0.5).round()),
        task: task,
      );

      if (audioResult.status != DownloadStatus.completed) {
        return audioResult;
      }

      if (!_activeDownloads.containsKey(task.id)) {
        _log('MUX: Cancelled during audio download');
        return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
      }

      onStep(const DownloadStep('processing', 'Muxing video + audio...'));
      _log('MUX STEP 3: FFmpeg muxing...');

      bool muxed = false;
      try {
        final result = await Process.run('ffmpeg', [
          '-y', '-i', videoTempPath, '-i', audioTempPath,
          '-c:v', 'copy', '-c:a', 'aac',
          '-map', '0:v:0', '-map', '1:a:0',
          outputPath,
        ]).timeout(const Duration(seconds: 120));

        muxed = result.exitCode == 0;
        _log('MUX STEP 3: FFmpeg exit=${result.exitCode}');
        if (!muxed) _log('MUX STEP 3: stderr=${result.stderr}');
      } catch (e) {
        _log('MUX STEP 3: FFmpeg failed (non-fatal): $e');
      }

      String finalPath;
      int fileBytes;

      if (muxed) {
        await _cleanupTempFiles([videoTempPath, audioTempPath]);
        final f = File(outputPath);
        fileBytes = await f.exists() ? await f.length() : 0;
        finalPath = outputPath;
      } else {
        final videoFile = File(videoTempPath);
        final fallbackPath = '$dir/$safeTitle.$videoExt';
        if (await videoFile.exists()) {
          await videoFile.rename(fallbackPath);
        }
        await File(audioTempPath).delete().catchError((_) {});
        final fallbackFile = File(fallbackPath);
        fileBytes = await fallbackFile.exists() ? await fallbackFile.length() : 0;
        finalPath = fallbackPath;
        _log('MUX: Fallback to video-only: $finalPath');
      }

      _log('MUX DONE: path=$finalPath size=$fileBytes (${(fileBytes / 1024 / 1024).toStringAsFixed(1)} MB) muxed=$muxed');

      if (fileBytes == 0) {
        return task.copyWith(status: 'failed', error: 'Downloaded file is empty', errorCode: 'fileEmpty');
      }

      onProgress(1.0, fileBytes);

      return task.copyWith(
        status: 'completed',
        progress: 1.0,
        bytesDownloaded: fileBytes,
        totalBytes: fileBytes,
        filePath: finalPath,
      );
    } catch (e, st) {
      _log('[ERROR] MUX EXCEPTION: $e');
      _log('[ERROR] MUX STACK: $st');
      await _cleanupTempFiles([videoTempPath, audioTempPath, outputPath]);
      return task.copyWith(status: 'failed', error: 'Download failed', errorCode: 'generic');
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
  }) async {
    _log('HTTP GET: ${url.host}${url.path.substring(0, url.path.length.clamp(0, 40))}...');
    final sw = Stopwatch()..start();

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
      request.headers.set('Range', 'bytes=0-');
      request.followRedirects = true;
      request.maxRedirects = 10;

      _log('HTTP: Sending request with Range: bytes=0-...');
      final response = await request.close().timeout(
        responseTimeout,
        onTimeout: () {
          _log('HTTP: getResponse timed out (${responseTimeout.inSeconds}s)');
          throw TimeoutException('Server response timed out');
        },
      );

      _log('HTTP: status=${response.statusCode} contentLength=${response.contentLength} contentType=${response.headers.contentType}');

      if (response.statusCode != 200 && response.statusCode != 206) {
        _log('HTTP FAILED: status=${response.statusCode}');
        String detail = '';
        try {
          final text = await response.transform(utf8.decoder).join();
          final m = RegExp(r'"detail"\s*:\s*"([^"]+)"').firstMatch(text);
          if (m != null) detail = ' - ${m.group(1)}';
        } catch (_) {}
        if (response.statusCode == 403) {
          return task.copyWith(status: 'failed', error: 'HTTP 403$detail', errorCode: 'http403');
        }
        return task.copyWith(status: 'failed', error: 'HTTP ${response.statusCode}$detail', errorCode: 'httpError');
      }

      final responseBytes = response.contentLength;
      final effectiveTotal = responseBytes > 0 ? responseBytes : totalBytes;
      _log('HTTP: effectiveTotal=$effectiveTotal (${(effectiveTotal / 1024 / 1024).toStringAsFixed(1)} MB)');

      final file = File(filePath);
      final fileSink = file.openWrite();
      sink = fileSink;
      int bytesDownloaded = 0;
      int chunkCount = 0;
      int limitBps = 0;
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
          await fileSink.close();
          await file.delete().catchError((_) {});
          throw Exception('Download cancelled');
        }

        fileSink.add(chunk);
        bytesDownloaded += chunk.length;
        chunkCount++;
        final progress = effectiveTotal > 0 ? bytesDownloaded / effectiveTotal : 0.0;
        onProgress(progress, bytesDownloaded);

        if (limitBps > 0) {
          final targetMs = bytesDownloaded * 1000.0 / limitBps;
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
      sw.stop();

      _log('HTTP: Stream finished, closing file...');
      final verified = await file.exists();
      final size = await file.length();
      _log('HTTP DONE: exists=$verified size=$size (${(size / 1024 / 1024).toStringAsFixed(1)} MB) time=${sw.elapsedMilliseconds}ms');

      if (!verified || size == 0) {
        return task.copyWith(status: 'failed', error: 'Downloaded file is empty', errorCode: 'fileEmpty');
      }

      onProgress(1.0, size);

      return task.copyWith(
        status: 'completed',
        progress: 1.0,
        bytesDownloaded: size,
        totalBytes: size,
        filePath: filePath,
      );
    } catch (e) {
      sw.stop();
      try {
        await sink?.close();
      } catch (_) {}
      _log('[ERROR] HTTP EXCEPTION: $e time=${sw.elapsedMilliseconds}ms');
      if (e is TimeoutException) {
        return task.copyWith(status: 'failed', error: 'Connection timed out', errorCode: 'connectionTimeout');
      }
      if (e.toString().contains('cancelled') || e.toString().contains('Cancel')) {
        return task.copyWith(status: 'cancelled', errorCode: 'cancelled');
      }
      return task.copyWith(status: 'failed', error: 'Connection failed', errorCode: 'connectionFailed');
    } finally {
      httpClient.close();
    }
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
    final idMatch = RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/|/embed/|/v/)([A-Za-z0-9_-]{11})').firstMatch(url);
    if (idMatch != null) return idMatch.group(1);

    final uri = Uri.tryParse(url);
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

      if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'embed') {
        final id = uri.pathSegments.last;
        if (id.length == 11) return id;
      }

      if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'v') {
        final id = uri.pathSegments.last;
        if (id.length == 11) return id;
      }
    }

    if (url.length == 11 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(url)) {
      return url;
    }
    return null;
  }
}
