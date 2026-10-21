import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/storage_service.dart';
import '../services/media_metadata_service.dart';

class TrashEntry {
  /// Original filename shown to the user.
  final String filename;

  /// Actual file name inside the trash folder. Older indexes did not store
  /// it, so [fromJson] falls back to [filename].
  final String storedName;
  final int size;
  final int deletedAt;
  final String thumbName;

  TrashEntry({
    required this.filename,
    String? storedName,
    required this.size,
    required this.deletedAt,
    this.thumbName = '',
  }) : storedName = (storedName == null || storedName.isEmpty)
            ? filename
            : storedName;

  bool get hasThumb => thumbName.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'storedName': storedName,
        'size': size,
        'deletedAt': deletedAt,
        'thumbName': thumbName,
      };

  factory TrashEntry.fromJson(Map<String, dynamic> json) => TrashEntry(
        filename: json['filename'] ?? '',
        storedName: json['storedName'] as String?,
        size: json['size'] ?? 0,
        deletedAt: json['deletedAt'] ?? 0,
        thumbName: json['thumbName'] ?? '',
      );
}

/// Real trash: the file is moved (never copied destructively), indexed with
/// the name it will be restored under, and only removed from disk on an
/// explicit permanent delete or after the retention period.
class TrashService {
  static final TrashService instance = TrashService._();
  TrashService._();

  static const int retentionDays = 7;

  Directory get _dir => Directory('${StorageService.instance.appDir.path}/trash');
  File get _indexFile => File('${_dir.path}/index.json');
  String get trashPath => _dir.path;

  /// Serializes index mutations. Two simultaneous deletes would otherwise
  /// read the same index and the second write would resurrect the first
  /// entry (or drop it silently).
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final completer = Completer<void>();
    final previous = _queue;
    _queue = completer.future;
    return previous.then((_) => action()).whenComplete(completer.complete);
  }

  static String baseNameOf(String filename) => filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;

  static String extensionOf(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot > 0 ? filename.substring(dot) : '';
  }

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
  }

  Future<List<TrashEntry>> _readIndex() async {
    try {
      if (!await _indexFile.exists()) return [];
      final content = await _indexFile.readAsString();
      if (content.trim().isEmpty) return [];
      final list = jsonDecode(content) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => TrashEntry.fromJson(Map<String, dynamic>.from(e)))
          .where((e) =>
              e.filename.isNotEmpty &&
              !e.filename.contains('/') &&
              !e.filename.contains('\\') &&
              !e.storedName.contains('/') &&
              !e.storedName.contains('\\') &&
              !e.thumbName.contains('/') &&
              !e.thumbName.contains('\\'))
          .toList();
    } catch (e) {
      log('index unreadable: $e');
      return [];
    }
  }

  Future<void> _writeIndex(List<TrashEntry> entries) async {
    await _ensureDir();
    final temp = File('${_indexFile.path}.tmp');
    await temp.writeAsString(
      jsonEncode(entries.map((e) => e.toJson()).toList()),
      flush: true,
    );
    try {
      await temp.rename(_indexFile.path);
    } catch (_) {
      // Windows cannot always replace an open file atomically; keep the
      // backup of the previous index before the fallback write.
      try {
        if (await _indexFile.exists()) {
          await _indexFile.copy('${_indexFile.path}.bak');
        }
      } catch (_) {}
      await temp.copy(_indexFile.path);
      try {
        await temp.delete();
      } catch (_) {}
    }
  }

  Future<void> _move(File src, File dst) async {
    try {
      await src.rename(dst.path);
    } catch (_) {
      await src.copy(dst.path);
      await src.delete();
    }
  }

  String uniqueNameIn(String dirPath, String filename) {
    if (!File('$dirPath/$filename').existsSync()) return filename;
    final dot = filename.lastIndexOf('.');
    final name = dot > 0 ? filename.substring(0, dot) : filename;
    final ext = dot > 0 ? filename.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '$name ($i)$ext';
      if (!File('$dirPath/$candidate').existsSync()) return candidate;
    }
    return '$name (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  String _uniqueTrashName(String filename) {
    final dot = filename.lastIndexOf('.');
    final name = dot > 0 ? filename.substring(0, dot) : filename;
    final ext = dot > 0 ? filename.substring(dot) : '';
    var candidate = filename;
    var attempt = 1;
    while (File('${_dir.path}/$candidate').existsSync()) {
      candidate = '$name (${DateTime.now().millisecondsSinceEpoch}-$attempt)$ext';
      attempt++;
      if (attempt > 1000) break;
    }
    return candidate;
  }

  /// Returns the entry on success, or null when the file does not exist or
  /// the index could not be updated. The caller must not pretend it worked.
  Future<TrashEntry?> moveToTrash(String filename) => _serial(() async {
        if (filename.isEmpty ||
            filename.contains('/') ||
            filename.contains('\\')) {
          log('refusing invalid filename: $filename');
          return null;
        }
        await _ensureDir();
        final storage = StorageService.instance;
        final src = File('${storage.downloadPath}/$filename');
        if (!await src.exists()) {
          log('source does not exist: $filename');
          return null;
        }

        final size = await src.length();
        final storedName = _uniqueTrashName(filename);
        final dstMedia = File('${_dir.path}/$storedName');
        final moved = <_MoveRecord>[];

        try {
          await _move(src, dstMedia);
          moved.add(_MoveRecord(src, dstMedia));

          // Thumbnails live in the private thumb cache, not beside the media.
          // Check both locations so files created by older versions migrate.
          File? srcThumb;
          final base = baseNameOf(filename);
          for (final candidate in [
            File('${storage.thumbDir.path}/$base.jpg'),
            File('${storage.thumbDir.path}/$base.png'),
            File('${storage.thumbDir.path}/$base.jpeg'),
            File('${storage.downloadPath}/$base.jpg'),
            File('${storage.downloadPath}/$base.png'),
          ]) {
            if (await candidate.exists()) {
              srcThumb = candidate;
              break;
            }
          }
          String thumbName = '';
          if (srcThumb != null) {
            final ext = extensionOf(srcThumb.path);
            thumbName = '$storedName.thumb${ext.isEmpty ? '.jpg' : ext}';
            final dstThumb = File('${_dir.path}/$thumbName');
            await _move(srcThumb, dstThumb);
            moved.add(_MoveRecord(srcThumb, dstThumb));
          }

          final srcMeta = File('${storage.downloadPath}/$base.meta.json');
          if (await srcMeta.exists()) {
            final dstMeta = File('${_dir.path}/$storedName.meta.json');
            await _move(srcMeta, dstMeta);
            moved.add(_MoveRecord(srcMeta, dstMeta));
          }

          final entry = TrashEntry(
            filename: filename,
            storedName: storedName,
            size: size,
            deletedAt: DateTime.now().millisecondsSinceEpoch,
            thumbName: thumbName,
          );
          final index = await _readIndex();
          index.removeWhere((e) => e.storedName == storedName);
          index.add(entry);
          await _writeIndex(index);
          return entry;
        } catch (e) {
          log('moveToTrash failed for $filename: $e');
          // Roll back so a failed index write never hides the media.
          for (final record in moved.reversed) {
            try {
              if (await record.dst.exists()) {
                await _move(record.dst, record.src);
              }
            } catch (_) {}
          }
          return null;
        }
      });

  Future<List<TrashEntry>> list() => _serial(() async {
        await purgeExpiredLocked();
        final index = await _readIndex();
        index.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
        return index;
      });

  /// Returns true only when the media is back in the downloads folder.
  /// A missing file leaves the entry in the trash and reports failure.
  Future<bool> restore(TrashEntry entry) => _serial(() async {
        final storage = StorageService.instance;
        final index = await _readIndex();
        final mediaFile = File('${_dir.path}/${entry.storedName}');
        if (!await mediaFile.exists()) {
          log('restore: media missing for ${entry.filename}');
          return false;
        }

        try {
          final restoredName =
              uniqueNameIn(storage.downloadPath, entry.filename);
          final base = baseNameOf(restoredName);
          await _move(
            mediaFile,
            File('${storage.downloadPath}/$restoredName'),
          );

          if (entry.hasThumb) {
            final thumbFile = File('${_dir.path}/${entry.thumbName}');
            if (await thumbFile.exists()) {
              final ext = extensionOf(entry.thumbName);
              await _move(
                thumbFile,
                File('${storage.thumbDir.path}/$base${ext.isEmpty ? '.jpg' : ext}'),
              );
            }
          }

          final metaFile = File('${_dir.path}/${entry.storedName}.meta.json');
          if (await metaFile.exists()) {
            await _move(
              metaFile,
              File('${storage.downloadPath}/$base.meta.json'),
            );
          }

          if (restoredName != entry.filename) {
            await MediaMetadataService().renameFileData(
              entry.filename,
              restoredName,
            );
          }

          index.removeWhere((e) => e.storedName == entry.storedName);
          await _writeIndex(index);
          return true;
        } catch (e) {
          log('restore failed for ${entry.filename}: $e');
          return false;
        }
      });

  /// True only when every existing file was deleted and the index was
  /// updated. Missing files are not an error (already gone).
  Future<bool> deleteForever(TrashEntry entry) => _serial(() async {
        final index = await _readIndex();
        final paths = <String>[
          '${_dir.path}/${entry.storedName}',
          '${_dir.path}/${entry.storedName}.meta.json',
          if (entry.hasThumb) '${_dir.path}/${entry.thumbName}',
          // Legacy layout (pre storedName): thumbnail beside the media.
          if (entry.hasThumb && entry.storedName == entry.filename)
            '${_dir.path}/${entry.thumbName}',
        ];
        for (final path in paths.toSet()) {
          final file = File(path);
          if (!await file.exists()) continue;
          try {
            await file.delete();
          } catch (e) {
            log('deleteForever failed for $path: $e');
            return false;
          }
        }
        index.removeWhere((e) => e.storedName == entry.storedName);
        try {
          await _writeIndex(index);
        } catch (e) {
          log('deleteForever index write failed: $e');
          return false;
        }
        try {
          await MediaMetadataService().removeFileData(entry.filename);
        } catch (_) {}
        return true;
      });

  Future<int> emptyTrash() => _serial(() async {
        final index = await _readIndex();
        var removed = 0;
        for (final entry in List.of(index)) {
          if (await deleteForeverLocked(entry)) removed++;
        }
        return removed;
      });

  Future<void> purgeExpired() => _serial(purgeExpiredLocked);

  Future<void> purgeExpiredLocked() async {
    final index = await _readIndex();
    if (index.isEmpty) return;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    final expired = index.where((e) => e.deletedAt < cutoff).toList();
    for (final entry in expired) {
      await deleteForeverLocked(entry);
    }
  }

  Future<int> count() async {
    await purgeExpired();
    return (await _readIndex()).length;
  }

  /// Same as [deleteForever] but does not take the lock (used inside it).
  Future<bool> deleteForeverLocked(TrashEntry entry) async {
    final index = await _readIndex();
    final paths = <String>[
      '${_dir.path}/${entry.storedName}',
      '${_dir.path}/${entry.storedName}.meta.json',
      if (entry.hasThumb) '${_dir.path}/${entry.thumbName}',
    ];
    for (final path in paths.toSet()) {
      final file = File(path);
      if (!await file.exists()) continue;
      try {
        await file.delete();
      } catch (e) {
        log('deleteForever failed for $path: $e');
        return false;
      }
    }
    index.removeWhere((e) => e.storedName == entry.storedName);
    await _writeIndex(index);
    try {
      await MediaMetadataService().removeFileData(entry.filename);
    } catch (_) {}
    return true;
  }

  static void log(String msg) => debugPrint('[TRASH] $msg');
}

class _MoveRecord {
  final File src;
  final File dst;
  _MoveRecord(this.src, this.dst);
}
