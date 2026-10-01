import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static StorageService? _instance;
  static const _channel = MethodChannel('com.example.vibegrab/storage');
  late Directory _appDir;
  Directory? _downloadDir;
  String? _customDirUri;
  bool _initialized = false;

  static const _downloadDirKey = 'vibegrab_download_dir_name';
  static const _customDirUriKey = 'vibegrab_custom_dir_uri';
  static const _customDirPathKey = 'vibegrab_custom_dir_path';
  static const defaultDirName = 'VibeGrab';

  StorageService._();

  static StorageService get instance {
    _instance ??= StorageService._();
    return _instance!;
  }

  static String _ts() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
  }

  void _log(String msg) => debugPrint('[STORAGE] ${_ts()} $msg');

  Directory get appDir => _appDir;
  Directory get downloadDir => _downloadDir!;
  String get downloadPath => _downloadDir?.path ?? '';
  String? get customDirUri => _customDirUri;
  bool get hasCustomDir => _customDirUri != null && _customDirUri!.isNotEmpty;

  Future<void> init() async {
    if (_initialized) return;
    _appDir = await getApplicationDocumentsDirectory();
    _log('appDir=${_appDir.path}');

    final prefs = await SharedPreferences.getInstance();

    _customDirUri = prefs.getString(_customDirUriKey);
    final customPath = prefs.getString(_customDirPathKey);

    if (_customDirUri != null && customPath != null) {
      final customDir = Directory(customPath);
      if (await customDir.exists()) {
        final canWrite = await testDirectoryWritable(customDir.path);
        if (canWrite) {
          _downloadDir = customDir;
          _log('Using custom dir: ${customDir.path}');
          _initialized = true;
          return;
        } else {
          _log('Custom dir NOT writable: ${customDir.path} — falling back to phone downloads');
          await _clearCustomDir();
        }
      } else {
        _log('Custom dir does not exist: $customPath — falling back to phone downloads');
        await _clearCustomDir();
      }
    }

    final phoneDir = await _getPhoneDownloadsDir();
    if (phoneDir != null) {
      final canWrite = await testDirectoryWritable(phoneDir.path);
      if (canWrite) {
        _downloadDir = phoneDir;
        _log('Using phone Downloads: ${phoneDir.path}');
        _initialized = true;
        return;
      } else {
        _log('Phone Downloads NOT writable — falling back to app-private');
      }
    }

    final dirName = prefs.getString(_downloadDirKey) ?? defaultDirName;
    _downloadDir = Directory('${_appDir.path}/$dirName');
    if (!await _downloadDir!.exists()) {
      await _downloadDir!.create(recursive: true);
    }
    _log('Using app-private dir: ${_downloadDir!.path}');
    _initialized = true;
  }

  Future<bool> testDirectoryWritable(String dirPath) async {
    _log('Testing directory writable: $dirPath');
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        _log('Directory does not exist: $dirPath');
        return false;
      }

      final testFile = File('$dirPath/.vibegrab_write_test');
      await testFile.writeAsString('test');
      final content = await testFile.readAsString();
      await testFile.delete();
      _log('Write test PASSED: $dirPath (wrote and deleted test file)');
      return content == 'test';
    } catch (e) {
      _log('Write test FAILED: $dirPath — $e');
      return false;
    }
  }

  Future<void> _clearCustomDir() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_customDirUriKey);
    await prefs.remove(_customDirPathKey);
    _customDirUri = null;
  }

  Future<void> setCustomDownloadDir(String uriString, String path) async {
    final canWrite = await testDirectoryWritable(path);
    if (!canWrite) {
      _log('setCustomDownloadDir: directory not writable, using phone downloads');
      _log('Requested path: $path');
      final phoneDir = await _getPhoneDownloadsDir();
      if (phoneDir != null) {
        final phoneCanWrite = await testDirectoryWritable(phoneDir.path);
        if (phoneCanWrite) {
          _downloadDir = phoneDir;
          _log('setCustomDownloadDir fallback to phone Downloads: ${phoneDir.path}');
        } else {
          _downloadDir = Directory('${_appDir.path}/$defaultDirName');
          if (!await _downloadDir!.exists()) {
            await _downloadDir!.create(recursive: true);
          }
          _log('setCustomDownloadDir fallback to app-private');
        }
      } else {
        _downloadDir = Directory('${_appDir.path}/$defaultDirName');
        if (!await _downloadDir!.exists()) {
          await _downloadDir!.create(recursive: true);
        }
        _log('setCustomDownloadDir fallback to app-private');
      }
      await _clearCustomDir();
      return;
    }
    _customDirUri = uriString;
    _downloadDir = Directory(path);
    if (!await _downloadDir!.exists()) {
      await _downloadDir!.create(recursive: true);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customDirUriKey, uriString);
    await prefs.setString(_customDirPathKey, path);
    _log('setCustomDownloadDir OK: $path');
  }

  Future<void> resetToDefaultDir() async {
    _customDirUri = null;
    final phoneDir = await _getPhoneDownloadsDir();
    if (phoneDir != null) {
      final canWrite = await testDirectoryWritable(phoneDir.path);
      if (canWrite) {
        _downloadDir = phoneDir;
        _log('resetToDefaultDir: phone Downloads ${phoneDir.path}');
      } else {
        _downloadDir = Directory('${_appDir.path}/$defaultDirName');
        if (!await _downloadDir!.exists()) {
          await _downloadDir!.create(recursive: true);
        }
        _log('resetToDefaultDir: app-private ${_downloadDir!.path}');
      }
    } else {
      _downloadDir = Directory('${_appDir.path}/$defaultDirName');
      if (!await _downloadDir!.exists()) {
        await _downloadDir!.create(recursive: true);
      }
      _log('resetToDefaultDir: app-private ${_downloadDir!.path}');
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_customDirUriKey);
    await prefs.remove(_customDirPathKey);
    await prefs.setString(_downloadDirKey, 'VibeGrab');
  }

  Future<String?> pickDirectory() async {
    try {
      final result = await _channel.invokeMethod<Map>('pickDirectory');
      if (result != null) {
        final uri = result['uri'] as String?;
        final path = result['path'] as String?;
        if (uri != null && path != null) {
          final canWrite = await testDirectoryWritable(path);
          if (canWrite) {
            await setCustomDownloadDir(uri, path);
            return path;
          } else {
            _log('pickDirectory: chosen path not writable: $path');
            return null;
          }
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _getPhoneDownloadsDir() async {
    try {
      final result = await _channel.invokeMethod<Map>('getExternalStorageRoot');
      if (result == null) {
        _log('getExternalStorageRoot returned null');
        return null;
      }
      final rootPath = result['path'] as String?;
      if (rootPath == null || rootPath.isEmpty) {
        _log('getExternalStorageRoot path is null/empty');
        return null;
      }
      _log('External storage root: $rootPath');
      final downloadsDir = Directory('$rootPath/Download/VibeGrab');
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      final testFile = File('${downloadsDir.path}/.vibegrab_test');
      await testFile.writeAsString('test');
      final content = await testFile.readAsString();
      await testFile.delete();
      if (content == 'test') {
        _log('Phone Downloads verified: ${downloadsDir.path}');
        return downloadsDir;
      }
      _log('Phone Downloads write test failed');
      return null;
    } catch (e) {
      _log('Failed to get phone downloads dir: $e');
      return null;
    }
  }

  Future<void> logStorageState() async {
    _log('=== STORAGE STATE ===');
    _log('appDir=${_appDir.path}');
    _log('downloadDir=${_downloadDir?.path ?? "NULL"}');
    _log('hasCustomDir=$hasCustomDir');
    _log('customDirUri=$_customDirUri');

    if (_downloadDir != null) {
      final exists = await _downloadDir!.exists();
      _log('downloadDir.exists=$exists');
      if (exists) {
        final writable = await testDirectoryWritable(_downloadDir!.path);
        _log('downloadDir.writable=$writable');
      }
    }
    _log('=== END STORAGE STATE ===');
  }

  List<FileSystemEntity> listMediaFiles() {
    if (_downloadDir == null || !_downloadDir!.existsSync()) return [];
    return _downloadDir!
        .listSync()
        .whereType<File>()
        .where((f) => _isMediaFile(f.path))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
  }

  bool deleteFile(String filename) {
    if (_downloadDir == null) return false;
    final file = File('${_downloadDir!.path}/$filename');
    if (file.existsSync()) {
      file.deleteSync();
      return true;
    }
    return false;
  }

  File? getFile(String filename) {
    if (_downloadDir == null) return null;
    final file = File('${_downloadDir!.path}/$filename');
    return file.existsSync() ? file : null;
  }

  int getFileSize(String filename) {
    if (_downloadDir == null) return 0;
    final file = File('${_downloadDir!.path}/$filename');
    return file.existsSync() ? file.lengthSync() : 0;
  }

  static bool _isMediaFile(String path) {
    final ext = path.split('.').last.toLowerCase();
    return const {
      'mp4', 'mkv', 'webm', 'avi', 'mov',
      'm4a', 'mp3', 'opus', 'wav', 'flac', 'aac',
    }.contains(ext);
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String fileTypeFor(String ext) {
    if (const {'mp4', 'mkv', 'webm', 'avi', 'mov'}.contains(ext)) return 'video';
    if (const {'m4a', 'mp3', 'opus', 'wav', 'flac', 'aac'}.contains(ext)) return 'audio';
    return 'unknown';
  }
}
