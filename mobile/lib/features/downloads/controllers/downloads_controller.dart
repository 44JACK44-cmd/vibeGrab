import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/download_task.dart';
import '../../../services/local_download_service.dart';
import '../../../services/media_metadata_service.dart';
import '../../../services/download_notification_service.dart';
import '../../../services/download_persistence_service.dart';
import '../../../services/storage_service.dart';

class DownloadsController extends ChangeNotifier {
  final LocalDownloadService _downloadService;
  final DownloadNotificationService _notifService;
  final DownloadPersistenceService _persistence;

  DownloadsController({
    LocalDownloadService? downloadService,
    DownloadNotificationService? notifService,
    DownloadPersistenceService? persistence,
  })  : _downloadService = downloadService ?? LocalDownloadService(),
        _notifService = notifService ?? DownloadNotificationService(),
        _persistence = persistence ?? DownloadPersistenceService();

  String unknownErrorFallback = 'Unknown error';

  /// Finds an active or completed task for the same URL (no duplicates).
  DownloadTask? findDuplicate(String url) {
    if (url.isEmpty) return null;
    try {
      return _tasks.firstWhere((t) =>
          t.url == url &&
          (t.status == DownloadStatus.completed || t.isActive));
    } catch (_) {
      return null;
    }
  }

  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  bool _loading = false;
  bool get loading => _loading;

  String? _errorKey;
  String? get errorKey => _errorKey;

  bool _initialized = false;
  final Map<String, DateTime> _lastProgressNotify = {};
  final Map<String, int> _lastProgressBytes = {};
  final Map<String, DateTime> _lastProgressAt = {};
  int _activeCount = 0;
  int _maxConcurrent = 2;
  final List<DownloadTask> _pendingQueue = [];

  /// Tasks that already have a worker. This is the single source of truth
  /// against double starts: [_retryStuckTasks] used to requeue a task while
  /// its first worker was still awaiting the notification service, so two
  /// workers downloaded the same file and both consumed a slot.
  final Set<String> _runningTaskIds = {};

  /// The in-flight worker per task, so cancel/retry can wait for the previous
  /// one to unwind instead of racing it for the same file and slot.
  final Map<String, Future<void>> _workers = {};

  String get downloadPath => StorageService.instance.downloadPath;

  static String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
  }

  void _log(String msg) => debugPrint('[DOWNLOAD_QUEUE] ${_ts()} $msg');

  void setCallbacks({
    Function(String)? onCancelFromNotification,
    Function(String)? onRetryFromNotification,
  }) {}

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _log('Controller init called');

    _notifService.init();
    await StorageService.instance.init();
    await StorageService.instance.logStorageState();

    final prefs = await SharedPreferences.getInstance();
    _maxConcurrent = prefs.getInt('vibegrab_setting_max_concurrent') ?? 2;
    _log('maxConcurrent=$_maxConcurrent');

    final savedTasks = await _persistence.loadTasks();
    _log('Loaded ${savedTasks.length} saved tasks');
    for (final task in savedTasks) {
      _log('  saved: id=${task.id} status=${task.status.name} title=${task.title}');
    }

    if (savedTasks.isNotEmpty) {
      final List<DownloadTask> reQueued = [];
      for (final task in savedTasks) {
        if (task.isActive && !_tasks.any((t) => t.id == task.id)) {
          final reset = task.copyWith(status: 'queued', progress: 0.0, step: null);
          _tasks.add(reset);
          reQueued.add(reset);
          _log('Re-queued active task: ${task.id}');
        } else if (!task.isActive && !_tasks.any((t) => t.id == task.id)) {
          _tasks.add(task);
        }
      }
      notifyListeners();
      for (final task in reQueued) {
        _enqueueDownload(task);
      }
    }

    _migrateLegacyThumbnails();
    _cleanupLegacyTempSources();
    _loadLocalFiles();
    // Active tasks were already requeued above. Do not call
    // _retryStuckTasks() here: it would reset the status of the workers
    // started a few lines earlier and start a second copy of each one.
  }

  void _migrateLegacyThumbnails() {
    try {
      final storage = StorageService.instance;
      final dirPath = storage.downloadPath;
      if (dirPath.isEmpty) return;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final entries = dir.listSync().whereType<File>().toList();
      final mediaBaseNames = <String>{};
      for (final f in entries) {
        final name = f.path.split(Platform.pathSeparator).last;
        final dot = name.lastIndexOf('.');
        if (dot <= 0) continue;
        final ext = name.substring(dot + 1).toLowerCase();
        if (ext == 'jpg' || ext == 'json') continue;
        mediaBaseNames.add(name.substring(0, dot));
      }
      // Files owned by a queue task (e.g. a downloaded cover image) must
      // stay where the task expects them, otherwise its filePath dangles.
      final taskPaths = _tasks
          .map((t) => t.filePath)
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toSet();
      int moved = 0;
      for (final f in entries) {
        final name = f.path.split(Platform.pathSeparator).last;
        if (!name.toLowerCase().endsWith('.jpg')) continue;
        if (taskPaths.contains(f.path)) continue;
        final baseName = name.substring(0, name.length - 4);
        if (!mediaBaseNames.contains(baseName)) continue;
        final dest =
            File('${storage.thumbDir.path}${Platform.pathSeparator}$name');
        if (dest.existsSync()) {
          f.deleteSync();
        } else {
          f.renameSync(dest.path);
        }
        moved++;
      }
      if (moved > 0) {
        _log('Migrated $moved legacy thumbnails to private thumbs dir');
      }
    } catch (e) {
      _log('migrateLegacyThumbnails error: $e');
    }
  }

  void updateMaxConcurrent(int value) {
    _maxConcurrent = value;
    _log('maxConcurrent updated to $value');
    _reprocessQueue();
  }

  /// Removes the intermediate `__audio`/`__video` files that older builds
  /// left in the public Downloads folder after converting or muxing.
  ///
  /// New builds write those sources to the app cache, but without this
  /// migration an existing user would keep seeing the old leftovers as extra
  /// videos next to their finished MP3.
  void _cleanupLegacyTempSources() {
    try {
      final dirPath = StorageService.instance.downloadPath;
      if (dirPath.isEmpty) return;
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      final taskPaths = _tasks
          .map((t) => t.filePath)
          .whereType<String>()
          .where((p) => p.isNotEmpty)
          .toSet();
      // Do not touch a file that another (possibly old) worker created in the
      // last few minutes. Anything older is a leftover from a finished,
      // failed, or interrupted conversion.
      final cutoff = DateTime.now().subtract(const Duration(minutes: 10));
      var removed = 0;
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split(Platform.pathSeparator).last.toLowerCase();
        if (!name.contains('__audio.') && !name.contains('__video.')) continue;
        if (taskPaths.contains(entity.path)) continue;
        try {
          if (entity.lastModifiedSync().isAfter(cutoff)) continue;
          entity.deleteSync();
          removed++;
        } catch (_) {
          // Busy or already deleted: the library filter still hides it.
        }
      }
      if (removed > 0) {
        _log('Removed $removed legacy temporary source files');
      }
    } catch (e) {
      _log('cleanupLegacyTempSources error: $e');
    }
  }

  void _loadLocalFiles() {
    _loading = true;
    notifyListeners();

    try {
      final dir = StorageService.instance.downloadPath;
      if (dir.isNotEmpty) {
        final files = StorageService.instance.listMediaFiles();
        for (final file in files) {
          final filename = file.path.split(Platform.pathSeparator).last;
          final lower = filename.toLowerCase();
          // Never show half-written downloads as finished library items.
          if (lower.startsWith('.') ||
              lower.endsWith('.part') ||
              lower.endsWith('.tmp') ||
              lower.endsWith('.download') ||
              lower.endsWith('.crdownload') ||
              // Reserved names for the temporary source tracks that older
              // builds wrote next to the final file while converting/muxing.
              lower.contains('__audio.') ||
              lower.contains('__video.')) {
            continue;
          }
          try {
            if (file.lengthSync() <= 0) continue;
          } catch (_) {
            continue;
          }
          if (!_tasks.any((t) => t.filePath == file.path)) {
            final baseName = filename.contains('.')
                ? filename.substring(0, filename.lastIndexOf('.'))
                : filename;
            final metaPath = '$dir${Platform.pathSeparator}$baseName.meta.json';
            String? thumbUrl;
            String? title;
            try {
              final metaFile = File(metaPath);
              if (metaFile.existsSync()) {
                final content = metaFile.readAsStringSync();
                final meta = jsonDecode(content) as Map<String, dynamic>;
                thumbUrl = meta['thumbnail'] as String?;
                title = meta['title'] as String?;
              }
            } catch (_) {}

            _tasks.add(DownloadTask(
              id: 'local_${filename.hashCode}',
              url: '',
              title: title ?? filename,
              formatId: '',
              thumbnail: thumbUrl,
              status: DownloadStatus.completed,
              progress: 1.0,
              filePath: file.path,
              createdAt: file.statSync().modified.toIso8601String(),
            ));
          }
        }
      }
    } catch (e) {
      _log('_loadLocalFiles error: $e');
    }

    _loading = false;
    notifyListeners();
  }

  /// A double tap (format row + download button, or two quick taps) used to
  /// enqueue the same work twice. Both workers wrote a file, so one action
  /// produced duplicate downloads. Reject only an identical job that is
  /// still active: completed jobs can be downloaded again, and choosing a
  /// different format for the same URL is a legitimate action.
  ///
  /// The predicate is pure and public for the regression test.
  @visibleForTesting
  static bool isSameActiveJob(DownloadTask candidate, DownloadTask existing) {
    return existing.id == candidate.id ||
        (existing.isActive &&
            existing.url == candidate.url &&
            existing.formatId == candidate.formatId &&
            existing.mediaType == candidate.mediaType);
  }

  void addTask(DownloadTask task) {
    _log('enqueue task=${task.id} url=${task.url} format=${task.formatId} title=${task.title}');
    _log('downloadPath=${StorageService.instance.downloadPath}');

    final duplicate = _tasks.any((t) => isSameActiveJob(task, t));
    if (duplicate) {
      _log('skip duplicate task=${task.id} format=${task.formatId}');
      return;
    }

    _tasks.insert(0, task);
    _persistence.saveTask(task);
    notifyListeners();
    _enqueueDownload(task);
  }

  /// Enqueues a plain image download (e.g. the video cover) published to
  /// the device gallery on completion. [fileExt] must match the real
  /// format of the source image: the saved path drives both the gallery
  /// mime type and the extension the file is written with.
  DownloadTask addImageDownload(
      {required String imageUrl,
      required String title,
      String fileExt = 'jpg'}) {
    final ext = fileExt.trim().isEmpty ? 'jpg' : fileExt.trim();
    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: imageUrl,
      title: title,
      formatId: '',
      thumbnail: imageUrl,
      hasVideo: false,
      hasAudio: false,
      directUrl: imageUrl,
      fileExt: ext,
      createdAt: DateTime.now().toIso8601String(),
    );
    addTask(task);
    return task;
  }

  /// Direct file download for the in-app browser (pdf, zip, apk, audio or a
  /// plain media file). No provider/manifest is involved: the service
  /// streams [url] straight to the configured downloads folder.
  DownloadTask addDirectFileDownload({
    required String url,
    required String title,
    required String fileExt,
  }) {
    // The extension comes from a URL path. Strip anything that is not part of
    // a real extension so a crafted link cannot inject a path separator.
    var ext = fileExt
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (ext.isEmpty) ext = 'bin';
    if (ext.length > 10) ext = ext.substring(0, 10);
    final task = DownloadTask(
      id: 'dl_${DateTime.now().millisecondsSinceEpoch}',
      url: url,
      title: title,
      formatId: '',
      hasVideo: false,
      hasAudio: false,
      directUrl: url,
      fileExt: ext,
      createdAt: DateTime.now().toIso8601String(),
    );
    addTask(task);
    return task;
  }

  void _enqueueDownload(DownloadTask task) {
    _log('enqueue download: id=${task.id} activeCount=$_activeCount max=$_maxConcurrent');
    if (_activeCount < _maxConcurrent) {
      _startWorker(task);
    } else {
      _log('worker busy, adding to pending queue: ${task.id} (queue length=${_pendingQueue.length + 1})');
      _pendingQueue.add(task);
    }
  }

  /// Starts one worker and remembers its future. The map is what lets
  /// [cancelDownload]/[retryDownload] know whether the id still has code
  /// running for it.
  void _startWorker(DownloadTask task) {
    _log('worker available, starting task=${task.id}');
    final future = _startDownload(task);
    _workers[task.id] = future;
    future.whenComplete(() {
      if (identical(_workers[task.id], future)) _workers.remove(task.id);
    });
  }

  void _reprocessQueue() {
    _log('reprocessQueue: active=$_activeCount pending=${_pendingQueue.length}');
    while (_activeCount < _maxConcurrent && _pendingQueue.isNotEmpty) {
      final next = _pendingQueue.removeAt(0);
      final idx = _tasks.indexWhere((t) => t.id == next.id);
      if (idx != -1 && _tasks[idx].status == DownloadStatus.queued) {
        _log('picked task from queue: ${next.id}');
        _startWorker(_tasks[idx]);
      } else {
        _log('skipping task from queue: ${next.id} (status=${idx != -1 ? _tasks[idx].status.name : "not found"})');
      }
    }
  }

  Future<void> _startDownload(DownloadTask task) async {
    _log('executing task=${task.id}');
    final index = _tasks.indexWhere((t) => t.id == task.id);
    if (index == -1) {
      _log('ABORT: task not found in list: ${task.id}');
      return;
    }
    if (_runningTaskIds.contains(task.id)) {
      _log('ABORT: already running: ${task.id}');
      return;
    }
    if (_tasks[index].status != DownloadStatus.queued) {
      _log('ABORT: status=${_tasks[index].status.name} (expected queued): ${task.id}');
      return;
    }

    _runningTaskIds.add(task.id);
    _activeCount++;
    _tasks[index] = _tasks[index].copyWith(
      status: 'preparing',
      step: null,
      startedAt: DateTime.now().toIso8601String(),
    );
    notifyListeners();
    _log('status changed to preparing. activeCount=$_activeCount');

    try {
      await _notifService.startService();
    } catch (e) {
      _log('Notification service start failed (non-fatal): $e');
    }

    try {
      _log('calling _downloadService.startDownload for task: ${task.id}');
      final updatedTask = await _downloadService.startDownload(
        task: _tasks[index],
        onProgress: (progress, bytesDownloaded) {
          final now = DateTime.now();
          final lastNotify = _lastProgressNotify[task.id];
          if (lastNotify != null && now.difference(lastNotify).inMilliseconds < 150) {
            return;
          }
          _lastProgressNotify[task.id] = now;

          // Real transfer speed from the last sample (not an estimate from
          // the total size): the notification shows what the user gets now.
          final lastBytes = _lastProgressBytes[task.id] ?? 0;
          final elapsedMs = now.difference(_lastProgressAt[task.id] ?? now).inMilliseconds;
          var bytesPerSecond = 0;
          if (elapsedMs > 0 && bytesDownloaded > lastBytes) {
            bytesPerSecond = ((bytesDownloaded - lastBytes) * 1000 / elapsedMs).round();
          }
          _lastProgressBytes[task.id] = bytesDownloaded;
          _lastProgressAt[task.id] = now;

          final i = _tasks.indexWhere((t) => t.id == task.id);
          if (i != -1) {
            _tasks[i] = _tasks[i].copyWith(
              progress: progress,
              bytesDownloaded: bytesDownloaded,
              status: 'downloading',
              step: '${(progress * 100).toStringAsFixed(0)}%',
            );
            _notifService.updateProgress(
              taskId: task.id,
              title: task.title,
              progress: progress,
              bytesPerSecond: bytesPerSecond,
            );
            notifyListeners();
          }
        },
        onStep: (step) {
          final i = _tasks.indexWhere((t) => t.id == task.id);
          if (i != -1) {
            final statusMap = {
              'preparing': 'preparing',
              'resolving': 'resolving',
              'connecting': 'connecting',
              'downloading': 'downloading',
              'processing': 'processing',
              'saving': 'saving',
            };
            _tasks[i] = _tasks[i].copyWith(
              step: null,
              status: statusMap[step.step] ?? _tasks[i].status.name,
            );
            notifyListeners();
          }
        },
      );

      _lastProgressNotify.remove(task.id);
      _lastProgressBytes.remove(task.id);
      _lastProgressAt.remove(task.id);
      _log('Download returned: status=${updatedTask.status.name} filePath=${updatedTask.filePath} error=${updatedTask.error}');

      final i = _tasks.indexWhere((t) => t.id == task.id);
      if (i != -1) {
        _tasks[i] = updatedTask.copyWith(
          completedAt: updatedTask.status == DownloadStatus.completed
              ? DateTime.now().toIso8601String()
              : null,
        );
        _persistence.saveTask(_tasks[i]);

        if (updatedTask.status == DownloadStatus.completed) {
          _log('COMPLETED: ${task.id} -> ${updatedTask.filePath}');
          _notifService.showCompleted(taskId: task.id, title: task.title);
          _saveMetadata(_tasks[i]);
          _publishToGallery(_tasks[i]);
        } else if (updatedTask.status == DownloadStatus.failed) {
          _log('FAILED: ${task.id} -> ${updatedTask.error}');
          _notifService.showFailed(taskId: task.id, title: task.title, error: updatedTask.error ?? unknownErrorFallback);
        } else if (updatedTask.status == DownloadStatus.cancelled) {
          _log('CANCELLED: ${task.id}');
        }
        notifyListeners();
      } else {
        _log('WARNING: task ${task.id} not found in list after download');
      }
    } catch (e, st) {
      _log('[ERROR] _startDownload exception: $e');
      _log('[ERROR] Stack trace: $st');
      _lastProgressNotify.remove(task.id);
      _lastProgressBytes.remove(task.id);
      _lastProgressAt.remove(task.id);
      final i = _tasks.indexWhere((t) => t.id == task.id);
      if (i != -1) {
        _tasks[i] = _tasks[i].copyWith(status: 'failed', error: e.toString());
        _persistence.saveTask(_tasks[i]);
        _notifService.showFailed(taskId: task.id, title: task.title, error: e.toString());
        notifyListeners();
      }
    } finally {
      _runningTaskIds.remove(task.id);
      _activeCount--;
      _log('worker finished: activeCount=$_activeCount pending=${_pendingQueue.length}');
      _reprocessQueue();
      _stopServiceIfIdle();
    }
  }

  Future<void> _stopServiceIfIdle() async {
    if (_activeCount > 0 || _pendingQueue.isNotEmpty) return;
    try {
      await _notifService.stopService();
    } catch (e) {
      _log('stopService failed (non-fatal): $e');
    }
  }

  Future<void> _saveMetadata(DownloadTask task) async {
    if (task.filePath == null) return;
    try {
      final file = File(task.filePath!);
      if (!await file.exists()) {
        _log('_saveMetadata: file does not exist: ${task.filePath}');
        return;
      }
      final dir = file.parent.path;
      final fileName = task.filePath!.split(Platform.pathSeparator).last;
      final dot = fileName.lastIndexOf('.');
      final baseName = dot > 0 ? fileName.substring(0, dot) : fileName;
      final metaFile = File('$dir${Platform.pathSeparator}$baseName.meta.json');
      final meta = {
        'title': task.title,
        'thumbnail': task.thumbnail,
        'source': task.source,
        'url': task.url,
        'formatId': task.formatId,
        'createdAt': task.createdAt,
        'artist': task.source,
        'videoId': _extractVideoId(task.url),
      };
      await metaFile.writeAsString(jsonEncode(meta));
      _log('Metadata saved: ${metaFile.path}');

      if (task.thumbnail != null && task.thumbnail!.isNotEmpty) {
        _downloadThumbnailLocal(
          thumbnailUrl: task.thumbnail!,
          baseName: baseName,
        );
      }
    } catch (e) {
      _log('_saveMetadata error: $e');
    }
  }

  String? _extractVideoId(String url) {
    final idMatch = RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/|/embed/|/v/)([A-Za-z0-9_-]{11})').firstMatch(url);
    return idMatch?.group(1);
  }

  static const _appChannel = MethodChannel('com.example.vibegrab/app');
  static const _statusChannel = MethodChannel('com.example.vibegrab/status');

  static String _mimeForPath(String path) {
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return 'video/mp4';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'm4a':
        return 'audio/mp4';
      case 'mp3':
        return 'audio/mpeg';
      case 'opus':
        return 'audio/opus';
      case 'wav':
        return 'audio/wav';
      case 'flac':
        return 'audio/flac';
      case 'aac':
        return 'audio/aac';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      case 'apk':
        return 'application/vnd.android.package-archive';
      default:
        return 'application/octet-stream';
    }
  }

  static bool _isGalleryMedia(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = path.substring(dot + 1).toLowerCase();
    return const {
      'mp4', 'm4v', 'webm', 'mkv', 'mov', 'avi', //
      'm4a', 'mp3', 'opus', 'wav', 'flac', 'aac', //
      'jpg', 'jpeg', 'png', 'webp', 'gif',
    }.contains(ext);
  }

  Future<void> _publishToGallery(DownloadTask task) async {
    final path = task.filePath;
    if (path == null || path.isEmpty) return;
    // A browser download (pdf/zip/apk) already lives in the public
    // Downloads folder; copying it into the gallery would create a duplicate
    // and MediaStore would reject it anyway.
    if (!_isGalleryMedia(path)) return;
    final normalized = path.replaceAll('\\', '/');
    try {
      final isPublic = normalized.startsWith('/storage/') ||
          normalized.startsWith('/sdcard/') ||
          normalized.startsWith('/mnt/');
      if (isPublic) {
        await _appChannel.invokeMethod('scanMedia', {'paths': [path]});
        _log('Gallery scan requested: $path');
      } else {
        final name = normalized.split('/').last;
        final ok = await _statusChannel.invokeMethod<bool>('saveToGallery', {
          'path': path,
          'name': name,
          'mime': _mimeForPath(path),
        });
        _log('saveToGallery copy ok=$ok path=$path');
      }
    } catch (e) {
      _log('publishToGallery error: $e');
    }
  }

  Future<void> _downloadThumbnailLocal({
    required String thumbnailUrl,
    required String baseName,
  }) async {
    _log('[THUMBNAIL] url available=true');
    try {
      final request = await HttpClient().getUrl(Uri.parse(thumbnailUrl));
      request.headers.set('User-Agent', 'Mozilla/5.0');
      final response = await request.close().timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        _log('[THUMBNAIL] response=200');
        final bytes = await response.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
        final jpgPath =
            '${StorageService.instance.thumbDir.path}${Platform.pathSeparator}$baseName.jpg';
        await File(jpgPath).writeAsBytes(bytes);
        _log('[THUMBNAIL] saved path=$jpgPath');
        _log('[THUMBNAIL] size=${bytes.length}');
        _log('[THUMBNAIL] completed');
      } else {
        _log('[THUMBNAIL][WARN] thumbnail download failed status=${response.statusCode}');
      }
    } catch (e) {
      _log('[THUMBNAIL][WARN] thumbnail download failed: $e');
    }
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == DownloadStatus.completed || t.status == DownloadStatus.cancelled);
    _persistence.saveTasks(_tasks);
    notifyListeners();
  }

  Future<void> removeTask(String taskId) async {
    _log('removeTask: $taskId');
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    final task = _tasks[index];
    if (task.isActive) {
      await _downloadService.cancelDownload(taskId);
      // The worker may still be writing the file this method is about to
      // delete. Wait for it to unwind (the socket is already closed) instead
      // of letting it recreate the file after the delete.
      final worker = _workers[taskId];
      if (worker != null) {
        try {
          await worker.timeout(const Duration(seconds: 15));
        } catch (e) {
          _log('removeTask: worker for $taskId still running: ${e.runtimeType}');
        }
      }
    }
    _pendingQueue.removeWhere((t) => t.id == taskId);
    await _notifService.removeTask(taskId);

    if (task.filePath != null) {
      try {
        final file = File(task.filePath!);
        if (await file.exists()) {
          await file.delete();
          _log('Deleted file: ${task.filePath}');
        }
        final baseName = task.filePath!.split(Platform.pathSeparator).last.split('.').first;
        final dir = file.parent.path;
        final metaFile = File('$dir${Platform.pathSeparator}$baseName.meta.json');
        if (await metaFile.exists()) {
          await metaFile.delete();
        }
        final jpgFile = File('$dir${Platform.pathSeparator}$baseName.jpg');
        if (await jpgFile.exists()) {
          await jpgFile.delete();
        }
        try {
          final thumbJpg = File(
              '${StorageService.instance.thumbDir.path}${Platform.pathSeparator}$baseName.jpg');
          if (await thumbJpg.exists()) {
            await thumbJpg.delete();
          }
        } catch (_) {}
      } catch (e) {
        _log('Error deleting file: $e');
      }
    }

    _tasks.removeAt(index);
    _persistence.saveTasks(_tasks);
    if (task.isActive) {
      _reprocessQueue();
    }
    notifyListeners();
    // Deleting a download must also drop its favorite + history entries,
    // otherwise the Library keeps orphan cards that do nothing when tapped.
    final meta = MediaMetadataService();
    final name = task.filePath?.split(Platform.pathSeparator).last;
    if (name != null) {
      await meta.removeFileData(name);
    }
    if (task.title.isNotEmpty) {
      await meta.removeFileData(task.title);
    }
  }

  Future<void> cancelDownload(String taskId) async {
    _log('cancelDownload: $taskId');
    await _downloadService.cancelDownload(taskId);
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index != -1) {
      _tasks[index] = _tasks[index].copyWith(status: 'cancelled');
      _persistence.saveTask(_tasks[index]);
      notifyListeners();
    }
    _pendingQueue.removeWhere((t) => t.id == taskId);
    await _notifService.removeTask(taskId);
    // Do NOT drop the id from _runningTaskIds here: the worker still owns the
    // slot and the output file for a moment, and removing it let a retry start
    // a second worker for the same task (double slot, two writers on one file).
    final worker = _workers[taskId];
    if (worker != null) {
      try {
        await worker.timeout(const Duration(seconds: 15));
      } catch (e) {
        _log('cancelDownload: worker for $taskId did not unwind: ${e.runtimeType}');
      }
    }
    _reprocessQueue();
    _stopServiceIfIdle();
  }

  Future<void> cancelTask(String taskId) => cancelDownload(taskId);

  Future<void> retryDownload(String taskId) async {
    _log('retryDownload: $taskId');
    var index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;

    // A cancelled task may still have a worker unwinding. Wait for it before
    // marking the task queued, or that worker would write its old result over
    // the new status and a second download would start on the same file.
    final worker = _workers[taskId];
    if (worker != null) {
      _log('retryDownload: waiting for previous worker of $taskId');
      try {
        await worker.timeout(const Duration(seconds: 15));
      } catch (e) {
        _log('retryDownload: previous worker still running: ${e.runtimeType}');
      }
    }

    index = _tasks.indexWhere((t) => t.id == taskId);
    if (index == -1) return;
    final task = _tasks[index];
    _tasks[index] = task.copyWith(
      status: 'queued',
      progress: 0.0,
      error: null,
      step: null,
    );
    _persistence.saveTask(_tasks[index]);
    notifyListeners();
    _enqueueDownload(_tasks[index]);
  }

  Future<void> retryTask(String taskId) => retryDownload(taskId);
}
