import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'storage_service.dart';
import '../data/models/library_file.dart';

class LocalMediaService {
  static const _channel = MethodChannel('com.example.vibegrab/local_media');
  static const _storagePermKey = 'vibegrab_storage_perm_granted';

  static Future<bool> requestPermissions() async {
    final sdkVersion = await _getSdkVersion();

    bool allGranted;
    if (sdkVersion >= 33) {
      final video = await Permission.videos.request();
      final audio = await Permission.audio.request();
      allGranted = video.isGranted && audio.isGranted;
    } else if (sdkVersion > 0) {
      final storage = await Permission.storage.request();
      allGranted = storage.isGranted;
    } else {
      // The API level could not be read. Ask every declared media permission
      // and accept the set this Android version actually has: READ_EXTERNAL
      // on <= 32, READ_MEDIA_VIDEO/AUDIO on 33+. Asking only the "33+" pair
      // used to leave Android 11/12 permanently denied, because those groups
      // do not exist there.
      final results = await [
        Permission.storage,
        Permission.videos,
        Permission.audio,
      ].request();
      final storage = results[Permission.storage]?.isGranted ?? false;
      final video = results[Permission.videos]?.isGranted ?? false;
      final audio = results[Permission.audio]?.isGranted ?? false;
      allGranted = storage || (video && audio);
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
    }
    if (sdkVersion > 0) {
      final storage = await Permission.storage.status;
      return storage.isGranted;
    }
    // Unknown API level: the group that does not exist on this version
    // reports "denied", so accept any group that is actually granted.
    final storage = await Permission.storage.status;
    if (storage.isGranted) return true;
    final video = await Permission.videos.status;
    final audio = await Permission.audio.status;
    return video.isGranted && audio.isGranted;
  }

  /// Android API level, or 0 when the platform channel cannot answer.
  ///
  /// It used to default to 33: on Android 11/12 that made the app check
  /// READ_MEDIA_VIDEO/AUDIO (only exist from 33), which always report denied,
  /// so the Library could never load even after granting storage access.
  static Future<int> _getSdkVersion() async {
    try {
      final info = await _channel.invokeMethod<Map>('getAndroidSdkVersion');
      final sdk = info?['sdkVersion'];
      if (sdk is int && sdk > 0) return sdk;
    } catch (e) {
      debugPrint('[LOCAL_MEDIA] SDK version lookup failed: ${e.runtimeType}');
    }
    return 0;
  }

  static Future<List<LibraryFile>> getDeviceMedia() async {
    try {
      final result = await _channel.invokeMethod<List>('getDeviceMedia');
      if (result == null) return [];
      return result
          .map((item) => LibraryFile.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      // Keep the library usable, but leave the cause in the log: a silent []
      // made "no media found" look identical to a platform failure.
      debugPrint('[LOCAL_MEDIA] getDeviceMedia failed: ${e.runtimeType} $e');
      return [];
    }
  }

  /// Lists the files this app downloaded, reading sizes and metadata off the
  /// UI isolate. It used to be synchronous (listSync/statSync/readAsStringSync
  /// per file), which froze the Library while it opened or refreshed.
  static Future<List<LibraryFile>> getDownloadedFiles() async {
    final storage = StorageService.instance;
    final files = await storage.listMediaFilesAsync();
    final result = <LibraryFile>[];
    for (final file in files) {
      final name = file.path.split(Platform.pathSeparator).last;
      final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
      final baseName = name.contains('.')
          ? name.substring(0, name.lastIndexOf('.'))
          : name;

      int size = 0;
      DateTime modified;
      try {
        final stat = await file.stat();
        size = stat.size;
        modified = stat.modified;
      } catch (_) {
        continue; // vanished between list() and stat()
      }

      String? thumbUrl;
      String? title;
      String? source;

      final thumb = await storage.getThumbFileAsync(baseName);

      final metaFile = storage.getFile('$baseName.meta.json');
      if (metaFile != null && await metaFile.exists()) {
        try {
          final meta = jsonDecode(await metaFile.readAsString());
          if (meta is Map<String, dynamic>) {
            thumbUrl = meta['thumbnail'] as String?;
            title = meta['title'] as String?;
            source = meta['source'] as String?;
          }
        } catch (_) {
          // A corrupt sidecar must not hide the media file itself.
        }
      }

      result.add(LibraryFile(
        filename: name,
        title: title ?? _humanize(name),
        filePath: file.path,
        fileSize: size,
        fileSizeFormatted: StorageService.formatSize(size),
        fileType: StorageService.fileTypeFor(ext),
        extension: ext,
        createdAt: modified.toIso8601String(),
        thumbnail: thumb == null ? thumbUrl : null,
        thumbnailPath: thumb?.path,
        source: source ?? 'vibegrab',
        sourceType: 'downloaded',
      ));
    }
    return result;
  }

  static String _humanize(String filename) {
    var name = filename;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) name = name.substring(0, dotIndex);
    return name.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  }
}
