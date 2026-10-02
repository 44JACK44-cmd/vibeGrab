import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../services/storage_service.dart';
import '../services/media_metadata_service.dart';

class TrashEntry {
  final String filename;
  final int size;
  final int deletedAt;
  final String thumbName;

  TrashEntry({
    required this.filename,
    required this.size,
    required this.deletedAt,
    this.thumbName = '',
  });

  bool get hasThumb => thumbName.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'filename': filename,
        'size': size,
        'deletedAt': deletedAt,
        'thumbName': thumbName,
      };

  factory TrashEntry.fromJson(Map<String, dynamic> json) => TrashEntry(
        filename: json['filename'] ?? '',
        size: json['size'] ?? 0,
        deletedAt: json['deletedAt'] ?? 0,
        thumbName: json['thumbName'] ?? '',
      );
}

class TrashService {
  static final TrashService instance = TrashService._();
  TrashService._();

  static const int retentionDays = 7;

  Directory get _dir => Directory('${StorageService.instance.appDir.path}/trash');
  File get _indexFile => File('${_dir.path}/index.json');

  static String baseNameOf(String filename) => filename.contains('.')
      ? filename.substring(0, filename.lastIndexOf('.'))
      : filename;

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
  }

  Future<List<TrashEntry>> _readIndex() async {
    try {
      if (!await _indexFile.exists()) return [];
      final content = await _indexFile.readAsString();
      final list = jsonDecode(content) as List<dynamic>;
      return list
          .map((e) => TrashEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeIndex(List<TrashEntry> entries) async {
    await _ensureDir();
    await _indexFile.writeAsString(
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
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

  Future<TrashEntry?> moveToTrash(String filename) async {
    await _ensureDir();
    final storage = StorageService.instance;
    final src = File('${storage.downloadPath}/$filename');
    if (!src.existsSync()) return null;

    final size = await src.length();
    final base = baseNameOf(filename);
    String thumbName = '';

    final dstMedia = File('${_dir.path}/$filename');
    if (await dstMedia.exists()) await dstMedia.delete();
    await _move(src, dstMedia);

    final srcThumb = storage.getFile('$base.jpg') ??
        storage.getFile('$base.png') ??
        storage.getFile('$base.jpeg');
    if (srcThumb != null) {
      final thumbExt = srcThumb.path.contains('.')
          ? srcThumb.path.substring(srcThumb.path.lastIndexOf('.'))
          : '.jpg';
      thumbName = '$filename.thumb$thumbExt';
      final dstThumb = File('${_dir.path}/$thumbName');
      if (await dstThumb.exists()) await dstThumb.delete();
      await _move(srcThumb, dstThumb);
    }

    final srcMeta = storage.getFile('$base.meta.json');
    if (srcMeta != null) {
      final dstMeta = File('${_dir.path}/$filename.meta.json');
      if (await dstMeta.exists()) await dstMeta.delete();
      await _move(srcMeta, dstMeta);
    }

    final entry = TrashEntry(
      filename: filename,
      size: size,
      deletedAt: DateTime.now().millisecondsSinceEpoch,
      thumbName: thumbName,
    );
    final index = await _readIndex();
    index.removeWhere((e) => e.filename == filename);
    index.add(entry);
    await _writeIndex(index);
    return entry;
  }

  Future<List<TrashEntry>> list() async {
    await purgeExpired();
    final index = await _readIndex();
    index.sort((a, b) => b.deletedAt.compareTo(a.deletedAt));
    return index;
  }

  Future<void> restore(TrashEntry entry) async {
    final storage = StorageService.instance;
    final index = await _readIndex();

    final mediaFile = File('${_dir.path}/${entry.filename}');
    if (mediaFile.existsSync()) {
      final restoredName =
          uniqueNameIn(storage.downloadPath, entry.filename);
      final base = baseNameOf(restoredName);
      await _move(mediaFile, File('${storage.downloadPath}/$restoredName'));

      if (entry.hasThumb) {
        final thumbFile = File('${_dir.path}/${entry.thumbName}');
        if (thumbFile.existsSync()) {
          final ext = entry.thumbName.contains('.')
              ? entry.thumbName.substring(entry.thumbName.lastIndexOf('.'))
              : '.jpg';
          await _move(thumbFile, File('${storage.downloadPath}/$base$ext'));
        }
      }

      final metaFile = File('${_dir.path}/${entry.filename}.meta.json');
      if (metaFile.existsSync()) {
        await _move(metaFile, File('${storage.downloadPath}/$base.meta.json'));
      }
    }

    index.removeWhere((e) => e.filename == entry.filename);
    await _writeIndex(index);
  }

  Future<void> deleteForever(TrashEntry entry) async {
    final index = await _readIndex();
    for (final path in [
      '${_dir.path}/${entry.filename}',
      '${_dir.path}/${entry.filename}.meta.json',
      if (entry.hasThumb) '${_dir.path}/${entry.thumbName}',
    ]) {
      final f = File(path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }
    index.removeWhere((e) => e.filename == entry.filename);
    await _writeIndex(index);
    try {
      await MediaMetadataService().removeFileData(entry.filename);
    } catch (_) {}
  }

  Future<void> emptyTrash() async {
    final index = await _readIndex();
    for (final entry in List.of(index)) {
      await deleteForever(entry);
    }
  }

  Future<void> purgeExpired() async {
    final index = await _readIndex();
    if (index.isEmpty) return;
    final cutoff = DateTime.now()
        .subtract(const Duration(days: retentionDays))
        .millisecondsSinceEpoch;
    final expired = index.where((e) => e.deletedAt < cutoff).toList();
    for (final entry in expired) {
      await deleteForever(entry);
    }
  }

  Future<int> count() async {
    await purgeExpired();
    return (await _readIndex()).length;
  }

  static void log(String msg) => debugPrint('[TRASH] $msg');
}
