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
      case 'heic':
      case 'heif':
        return 'image/heic';
      case 'avif':
        return 'image/avif';
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

  final List<String> _dirPaths = [];
  String? get dirPath => _dirPaths.isEmpty ? null : _dirPaths.first;

  Future<StatusAccess> checkAccess() async {
    try {
      final res = await _channel.invokeMethod<Map>('checkAccess');
      final state = res?['state'] as String? ?? 'unsupported';
      _dirPaths.clear();
      final rawPaths = res?['paths'];
      if (rawPaths is List) {
        for (final value in rawPaths) {
          if (value is String && value.isNotEmpty) _dirPaths.add(value);
        }
      }
      final first = res?['path'] as String?;
      if (_dirPaths.isEmpty && first != null && first.isNotEmpty) {
        _dirPaths.add(first);
      }
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
    // Android 13+: READ_MEDIA_IMAGES / READ_MEDIA_VIDEO. Android 12 and
    // below maps these to READ_EXTERNAL_STORAGE. Request both so a device
    // that stores statuses as images or videos is covered; the OS ignores
    // the permission that does not exist on that version.
    await Permission.photos.request();
    await Permission.videos.request();
    if (Platform.isAndroid) {
      await Permission.storage.request();
    }
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
    if (await checkAccess() != StatusAccess.granted) return [];
    final statuses = <StatusFile>[];
    final seen = <String>{};
    for (final dirPath in List.of(_dirPaths)) {
      try {
        final dir = Directory(dirPath);
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final path = entity.path;
          if (!seen.add(path)) continue;
          final name = path.split(Platform.pathSeparator).last;
          if (name.startsWith('.')) continue;

          final stat = await entity.stat();
          // Status files are written by WhatsApp while the list is read. A
          // zero-byte (or currently-truncated) file is not a playable status.
          if (stat.size <= 0) continue;

          var ext = '';
          final dot = name.lastIndexOf('.');
          if (dot > 0) ext = name.substring(dot + 1).toLowerCase();

          // Sniff first. WhatsApp occasionally writes `.mp4` placeholders or
          // reuses names; the bytes decide whether this is image or video.
          final sniff = _sniffFile(entity);
          bool? sniffIsVideo;
          if (sniff != null) {
            if (sniff == 'mp4') {
              sniffIsVideo = true;
              // Keep a real video extension (3gp/webm/mov); replace a
              // misleading one (.txt, .tmp) with the sniffed container.
              if (!_videoExts.contains(ext)) ext = 'mp4';
            } else {
              sniffIsVideo = false;
              // Keep the real container/extension, not the misleading one.
              if (sniff != 'jpg' || ext.isEmpty) ext = sniff;
            }
          }

          bool isVideo;
          if (sniffIsVideo != null) {
            isVideo = sniffIsVideo;
          } else if (_videoExts.contains(ext)) {
            isVideo = true;
          } else if (_imageExts.contains(ext)) {
            isVideo = false;
          } else {
            // Unknown bytes and unknown extension: not a status we can show.
            continue;
          }

          statuses.add(StatusFile(
            file: entity,
            name: name,
            path: path,
            ext: ext.isEmpty ? (isVideo ? 'mp4' : 'jpg') : ext,
            size: stat.size,
            isVideo: isVideo,
            modifiedMs: stat.modified.millisecondsSinceEpoch,
          ));
        }
      } catch (e) {
        // One unreadable folder (WhatsApp Business, a ROM-specific path) must
        // not hide statuses that are readable elsewhere.
        debugPrint('[STATUS] list failed for $dirPath: $e');
      }
    }
    statuses.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
    return statuses;
  }

  Future<bool> saveToGallery(StatusFile status) async {
    try {
      // Re-check at save time: WhatsApp may have rotated the status while the
      // list was on screen.
      if (!await status.file.exists()) return false;
      final length = await status.file.length();
      if (length <= 0 || length != status.size) return false;
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

  /// Shares a status through the system sheet (Files already granted read
  /// access, no extra permission needed).
  Future<bool> share(StatusFile status) async {
    try {
      if (!await status.file.exists()) return false;
      final dot = status.name.lastIndexOf('.');
      final displayName =
          dot > 0 ? status.name : '${status.name}.${status.ext}';
      return await _channel.invokeMethod<bool>('shareFile', {
            'path': status.path,
            'name': displayName,
            'mime': status.mimeType,
          }) ??
          false;
    } catch (e) {
      debugPrint('[STATUS] share failed: $e');
      return false;
    }
  }

  /// Deletes a status from WhatsApp's folder (original file, not the copy).
  Future<bool> delete(StatusFile status) async {
    try {
      if (!await status.file.exists()) return false;
      await status.file.delete();
      return !await status.file.exists();
    } catch (e) {
      debugPrint('[STATUS] delete failed: $e');
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
      if (bytes.length >= 12 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        // ISO-BMFF is used by both video and HEIC/AVIF still images. Reading
        // the brand avoids showing a photo as an unplayable "video".
        final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
        if (brand == 'heic' ||
            brand == 'heix' ||
            brand == 'hevc' ||
            brand == 'hevx' ||
            brand == 'mif1' ||
            brand == 'msf1') {
          return 'heic';
        }
        if (brand == 'avif' || brand == 'avis') return 'avif';
        return 'mp4';
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
