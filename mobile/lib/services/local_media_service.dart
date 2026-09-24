import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'storage_service.dart';
import '../data/models/library_file.dart';

class LocalMediaService {
  static const _channel = MethodChannel('com.example.vibegrab/local_media');
  static const _storagePermKey = 'vibegrab_storage_perm_granted';

  static Future<bool> requestPermissions() async {
    bool allGranted = true;

    final androidInfo = await _channel.invokeMethod<Map>('getAndroidSdkVersion');
    final sdkVersion = androidInfo?['sdkVersion'] as int? ?? 0;

    if (sdkVersion >= 33) {
      final video = await Permission.videos.request();
      final audio = await Permission.audio.request();
      allGranted = video.isGranted && audio.isGranted;
    } else {
      final storage = await Permission.storage.request();
      allGranted = storage.isGranted;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_storagePermKey, allGranted);
    return allGranted;
  }

  static Future<bool> hasPermissions() async {
    final sdkVersion = await _getSdkVersion();

    if (sdkVersion >= 33) {
      final video = await Permission.videos.status;
      final audio = await Permission.audio.status;
      return video.isGranted && audio.isGranted;
    } else {
      final storage = await Permission.storage.status;
      return storage.isGranted;
    }
  }

  static Future<int> _getSdkVersion() async {
    try {
      final info = await _channel.invokeMethod<Map>('getAndroidSdkVersion');
      return info?['sdkVersion'] as int? ?? 33;
    } catch (_) {
      return 33;
    }
  }

  static Future<List<LibraryFile>> getDeviceMedia() async {
    try {
      final result = await _channel.invokeMethod<List>('getDeviceMedia');
      if (result == null) return [];
      return result
          .map((item) => LibraryFile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static List<LibraryFile> getDownloadedFiles() {
    final storage = StorageService.instance;
    final files = storage.listMediaFiles();
    return files.map((file) {
      final name = file.path.split('\\').last.split('/').last;
      final ext = name.split('.').last.toLowerCase();
      final stat = file.statSync();
      final baseName = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

      String? thumbUrl;
      String? title;
      String? source;
      String? thumbPath;

      final localJpg = storage.getFile('$baseName.jpg');
      final localPng = storage.getFile('$baseName.png');
      final localJpeg = storage.getFile('$baseName.jpeg');
      final foundLocalThumb = localJpg ?? localPng ?? localJpeg;
      if (foundLocalThumb != null && foundLocalThumb.existsSync()) {
        thumbPath = foundLocalThumb.path;
      }

      final metaFile = storage.getFile('$baseName.meta.json');
      if (metaFile != null && metaFile.existsSync()) {
        try {
          final content = metaFile.readAsStringSync();
          final meta = jsonDecode(content) as Map<String, dynamic>;
          thumbUrl = meta['thumbnail'] as String?;
          title = meta['title'] as String?;
          source = meta['source'] as String?;
        } catch (_) {}
      }

      return LibraryFile(
        filename: name,
        title: title ?? _humanize(name),
        filePath: file.path,
        fileSize: stat.size,
        fileSizeFormatted: StorageService.formatSize(stat.size),
        fileType: StorageService.fileTypeFor(ext),
        extension: ext,
        createdAt: stat.modified.toIso8601String(),
        thumbnail: thumbPath == null ? thumbUrl : null,
        thumbnailPath: thumbPath,
        source: source ?? 'vibegrab',
        sourceType: 'downloaded',
      );
    }).toList();
  }

  static String _humanize(String filename) {
    var name = filename;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) name = name.substring(0, dotIndex);
    return name.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  }
}
