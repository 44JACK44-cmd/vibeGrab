import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum StatusAccess { granted, needMedia, needManage, unsupported }

class StatusFile {
  final File file;
  final String name;
  final String path;
  final String ext;
  final int size;
  final bool isVideo;
  final int modifiedMs;

  const StatusFile({
    required this.file,
    required this.name,
    required this.path,
    required this.ext,
    required this.size,
    required this.isVideo,
    required this.modifiedMs,
  });

  String get mimeType {
    if (isVideo) {
      switch (ext) {
        case '3gp':
          return 'video/3gpp';
        case 'webm':
          return 'video/webm';
        case 'mov':
          return 'video/quicktime';
        case 'mkv':
          return 'video/x-matroska';
        default:
          return 'video/mp4';
      }
    }
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }
}

class StatusService {
  static final StatusService instance = StatusService._();
  StatusService._();

  static const _channel = MethodChannel('com.example.vibegrab/status');
  static const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif'};
  static const _videoExts = {'mp4', '3gp', 'mkv', 'webm', 'mov'};

  String? _dirPath;
  String? get dirPath => _dirPath;

  Future<StatusAccess> checkAccess() async {
    try {
      final res = await _channel.invokeMethod<Map>('checkAccess');
      final state = res?['state'] as String? ?? 'unsupported';
      _dirPath = res?['path'] as String?;
      switch (state) {
        case 'granted':
          return StatusAccess.granted;
        case 'need_media':
          return StatusAccess.needMedia;
        case 'need_manage':
          return StatusAccess.needManage;
        default:
          return StatusAccess.unsupported;
      }
    } catch (_) {
      return StatusAccess.unsupported;
    }
  }

  Future<bool> requestMediaPermission() async {
    await Permission.photos.request();
    await Permission.videos.request();
    return await checkAccess() == StatusAccess.granted;
  }

  Future<bool> requestManagePermission() async {
    await Permission.manageExternalStorage.request();
    if (await checkAccess() == StatusAccess.granted) return true;
    try {
      await _channel.invokeMethod<bool>('openAllFilesSettings');
    } catch (_) {}
    return false;
  }

  Future<List<StatusFile>> list() async {
    try {
      if (await checkAccess() != StatusAccess.granted || _dirPath == null) {
        return [];
      }
      final dir = Directory(_dirPath!);
      final statuses = <StatusFile>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path;
        final name = path.split(Platform.pathSeparator).last;
        if (name.startsWith('.')) continue;

        var ext = '';
        final dot = name.lastIndexOf('.');
        if (dot > 0) ext = name.substring(dot + 1).toLowerCase();

        bool isVideo;
        if (_videoExts.contains(ext)) {
          isVideo = true;
        } else if (_imageExts.contains(ext)) {
          isVideo = false;
        } else {
          final sniff = _sniffFile(entity);
          if (sniff == null) continue;
          isVideo = sniff == 'mp4';
          if (ext.isEmpty) ext = sniff;
        }

        final stat = await entity.stat();
        statuses.add(StatusFile(
          file: entity,
          name: name,
          path: path,
          ext: ext,
          size: stat.size,
          isVideo: isVideo,
          modifiedMs: stat.modified.millisecondsSinceEpoch,
        ));
      }
      statuses.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      return statuses;
    } catch (e) {
      debugPrint('[STATUS] list failed: $e');
      return [];
    }
  }

  Future<bool> saveToGallery(StatusFile status) async {
    try {
      final dot = status.name.lastIndexOf('.');
      final displayName =
          dot > 0 ? status.name : '${status.name}.${status.ext}';
      return await _channel.invokeMethod<bool>('saveToGallery', {
            'path': status.path,
            'name': displayName,
            'mime': status.mimeType,
          }) ??
          false;
    } catch (e) {
      debugPrint('[STATUS] save failed: $e');
      return false;
    }
  }

  String? _sniffFile(File file) {
    try {
      final raf = file.openSync();
      final bytes = raf.readSync(16);
      raf.closeSync();
      if (bytes.length >= 3 &&
          bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
        return 'jpg';
      }
      if (bytes.length >= 8 &&
          bytes[0] == 0x89 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4E &&
          bytes[3] == 0x47) {
        return 'png';
      }
      if (bytes.length >= 4 &&
          bytes[0] == 0x47 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x38) {
        return 'gif';
      }
      if (bytes.length >= 12 &&
          bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46 &&
          bytes[8] == 0x57 &&
          bytes[9] == 0x45 &&
          bytes[10] == 0x42 &&
          bytes[11] == 0x50) {
        return 'webp';
      }
      if (bytes.length >= 8 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        return 'mp4';
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
