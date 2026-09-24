import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/download_task.dart';
import '../../../services/local_download_service.dart';
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

  final List<DownloadTask> _tasks = [];
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);

  bool _loading = false;
  bool get loading => _loading;

  String? _errorKey;
  String? get errorKey => _errorKey;

  bool _initialized = false;
  final Map<String, DateTime> _lastProgressNotify = {};
  int _activeCount = 0;
  int _maxConcurrent = 2;
  final List<DownloadTask> _pendingQueue = [];

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
      for (final task in savedTasks) {
        if (task.isActive && !_tasks.any((t) => t.id == task.id)) {
          _tasks.add(task.copyWith(status: 'queued'));
          _log('Re-queued active task: ${task.id}');
        } else if (!task.isActive && !_tasks.any((t) => t.id == task.id)) {
          _tasks.add(task);
        }
      }
      notifyListeners();
    }

    _loadLocalFiles();
    _retryStuckTasks();
  }

  void updateMaxConcurrent(int value) {
    _maxConcurrent = value;
    _log('maxConcurrent updated to $value');
    _reprocessQueue();
  }

  void _retryStuckTasks() {
    final List<DownloadTask> stuckTasks = [];
    for (int i = 0; i < _tasks.length; i++) {
      if (_tasks[i].status == DownloadStatus.downloading ||
          _tasks[i].status == DownloadStatus.preparing ||
          _tasks[i].status == DownloadStatus.resolving ||
          _tasks[i].status == DownloadStatus.connecting ||
          _tasks[i].status == DownloadStatus.saving ||
          _tasks[i].status == DownloadStatus.processing) {
        _log('Resetting stuck task: ${_tasks[i].id} (${_tasks[i].status})');
        final reset = _tasks[i].copyWith(status: 'queued', progress: 0.0, step: null);
        _tasks[i] = reset;
        stuckTasks.add(reset);
      }
    }
    if (stuckTasks.isNotEmpty) {
      _log('Reprocessing ${stuckTasks.length} stuck tasks');
    }
    for (final task in stuckTasks) {
      _enqueueDownload(task);
    }
    _reprocessQueue();
    notifyListeners();
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

  void addTask(DownloadTask task) {
    _log('enqueue task=${task.id} url=${task.url} format=${task.formatId} title=${task.title}');
    _log('downloadPath=${StorageService.instance.downloadPath}');
    _tasks.insert(0, task);
    _persistence.saveTask(task);
    notifyListeners();
    _enqueueDownload(task);
  }

  void _enqueueDownload(DownloadTask task) {
    _log('enqueue download: id=${task.id} activeCount=$_activeCount max=$_maxConcurrent');
    if (_activeCount < _maxConcurrent) {
      _log('worker available, starting task=${task.id}');
      _startDownload(task);
    } else {
      _log('worker busy, adding to pending queue: ${task.id} (queue length=${_pendingQueue.length + 1})');
      _pendingQueue.add(task);
    }
  }

  void _reprocessQueue() {
    _log('reprocessQueue: active=$_activeCount pending=${_pendingQueue.length}');
    while (_activeCount < _maxConcurrent && _pendingQueue.isNotEmpty) {
      final next = _pendingQueue.removeAt(0);
      final idx = _tasks.indexWhere((t) => t.id == next.id);
      if (idx != -1 && _tasks[idx].status == DownloadStatus.queued) {
        _log('picked task from queue: ${next.id}');
        _startDownload(_tasks[idx]);
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
    if (_tasks[index].status != DownloadStatus.queued) {
      _log('ABORT: status=${_tasks[index].status.name} (expected queued): ${task.id}');
      return;
    }

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
        } else if (updatedTask.status == DownloadStatus.failed) {
          _log('FAILED: ${task.id} -> ${updatedTask.error}');
          _notifService.showFailed(taskId: task.id, title: task.title, error: updatedTask.error ?? 'Unknown error');
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
      final i = _tasks.indexWhere((t) => t.id == task.id);
      if (i != -1) {
        _tasks[i] = _tasks[i].copyWith(status: 'failed', error: e.toString());
        _persistence.saveTask(_tasks[i]);
        _notifService.showFailed(taskId: task.id, title: task.title, error: e.toString());
        notifyListeners();
      }
    } finally {
      _activeCount--;
      _log('worker finished: activeCount=$_activeCount pending=${_pendingQueue.length}');
      _reprocessQueue();
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
      final baseName = task.filePath!.split(Platform.pathSeparator).last.split('.').first;
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
          dir: dir,
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

  Future<void> _downloadThumbnailLocal({
    required String thumbnailUrl,
    required String dir,
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
        final jpgPath = '$dir${Platform.pathSeparator}$baseName.jpg';
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
    }
    _pendingQueue.removeWhere((t) => t.id == taskId);

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
      } catch (e) {
        _log('Error deleting file: $e');
      }
    }

    _tasks.removeAt(index);
    _persistence.saveTasks(_tasks);
    if (task.isActive) {
      _activeCount--;
      _reprocessQueue();
    }
    notifyListeners();
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
    _reprocessQueue();
  }

  Future<void> cancelTask(String taskId) => cancelDownload(taskId);

  Future<void> retryDownload(String taskId) async {
    _log('retryDownload: $taskId');
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index != -1) {
      final task = _tasks[index];
      _tasks[index] = task.copyWith(status: 'queued', progress: 0.0, error: null, step: null);
      _persistence.saveTask(_tasks[index]);
      notifyListeners();
      _enqueueDownload(_tasks[index]);
    }
  }

  Future<void> retryTask(String taskId) => retryDownload(taskId);
}
