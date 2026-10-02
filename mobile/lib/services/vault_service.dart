import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models/library_file.dart';
import '../services/storage_service.dart';
import '../services/trash_service.dart';

class VaultFile {
  final String name;
  final String path;
  final int size;
  final int modifiedMs;

  VaultFile({
    required this.name,
    required this.path,
    required this.size,
    required this.modifiedMs,
  });

  bool get isVideo => StorageService.fileTypeFor(_ext) == 'video';
  bool get isAudio => StorageService.fileTypeFor(_ext) == 'audio';
  String get _ext => name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

class VaultService {
  static final VaultService instance = VaultService._();
  VaultService._();

  static const _salt = 'VibeGrabVault1';
  static const _pinKey = 'vibegrab_vault_pin';
  static const _failsKey = 'vibegrab_vault_fails';
  static const _lockUntilKey = 'vibegrab_vault_lock_until';
  static const _maxFails = 5;
  static const _lockSeconds = 60;

  Directory get _dir =>
      Directory('${StorageService.instance.appDir.path}/vault');

  String hashPin(String pin) =>
      sha256.convert(utf8.encode('$_salt:$pin')).toString();

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) {
      await _dir.create(recursive: true);
    }
  }

  Future<bool> get isPinSet async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_pinKey) ?? '').isNotEmpty;
  }

  Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_pinKey, hashPin(pin));
    await prefs.setInt(_failsKey, 0);
    await prefs.remove(_lockUntilKey);
  }

  Future<bool> get isLocked async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_lockUntilKey) ?? 0;
    if (until == 0) return false;
    if (DateTime.now().millisecondsSinceEpoch >= until) {
      await prefs.remove(_lockUntilKey);
      await prefs.setInt(_failsKey, 0);
      return false;
    }
    return true;
  }

  Future<int> get lockSecondsLeft async {
    final prefs = await SharedPreferences.getInstance();
    final until = prefs.getInt(_lockUntilKey) ?? 0;
    if (until == 0) return 0;
    final left =
        ((until - DateTime.now().millisecondsSinceEpoch) / 1000).ceil();
    return left > 0 ? left : 0;
  }

  Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_pinKey) ?? '';
    if (stored.isEmpty) return false;
    if (stored == hashPin(pin)) {
      await prefs.setInt(_failsKey, 0);
      return true;
    }
    final fails = (prefs.getInt(_failsKey) ?? 0) + 1;
    if (fails >= _maxFails) {
      await prefs.setInt(_failsKey, 0);
      await prefs.setInt(
        _lockUntilKey,
        DateTime.now()
            .millisecondsSinceEpoch +
            _lockSeconds * 1000,
      );
    } else {
      await prefs.setInt(_failsKey, fails);
    }
    return false;
  }

  String pathFor(String name) => '${_dir.path}/$name';

  Future<List<VaultFile>> list() async {
    await _ensureDir();
    final files = _dir
        .listSync()
        .whereType<File>()
        .where((f) =>
            !f.path.endsWith('.meta.json') && !f.path.contains('.thumb.'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files.map((f) {
      final name = f.path.split(Platform.pathSeparator).last;
      final stat = f.statSync();
      return VaultFile(
        name: name,
        path: f.path,
        size: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    }).toList();
  }

  Future<String?> moveToVault(String filename) async {
    await _ensureDir();
    final storage = StorageService.instance;
    final src = File('${storage.downloadPath}/$filename');
    if (!src.existsSync()) return null;

    final base = TrashService.baseNameOf(filename);

    var dstName = filename;
    if (File('${_dir.path}/$dstName').existsSync()) {
      dstName = TrashService.instance
          .uniqueNameIn(_dir.path, filename);
    }
    await _move(src, File('${_dir.path}/$dstName'));

    final srcThumb = storage.getFile('$base.jpg') ??
        storage.getFile('$base.png') ??
        storage.getFile('$base.jpeg');
    if (srcThumb != null) {
      final thumbExt = srcThumb.path.contains('.')
          ? srcThumb.path.substring(srcThumb.path.lastIndexOf('.'))
          : '.jpg';
      await _move(srcThumb, File('${_dir.path}/$dstName.thumb$thumbExt'));
    }
    return dstName;
  }

  Future<String?> restoreFromVault(String vaultName) async {
    final storage = StorageService.instance;
    final src = File('${_dir.path}/$vaultName');
    if (!src.existsSync()) return null;

    final restored =
        TrashService.instance.uniqueNameIn(storage.downloadPath, vaultName);
    final base = TrashService.baseNameOf(restored);
    await _move(src, File('${storage.downloadPath}/$restored'));

    for (final ext in ['jpg', 'png', 'jpeg']) {
      final thumb = File('${_dir.path}/$vaultName.thumb.$ext');
      if (thumb.existsSync()) {
        await _move(thumb, File('${storage.downloadPath}/$base.$ext'));
        break;
      }
    }
    return restored;
  }

  Future<void> deleteFromVault(String vaultName) async {
    final media = File('${_dir.path}/$vaultName');
    if (await media.exists()) {
      try {
        await media.delete();
      } catch (_) {}
    }
    for (final ext in ['jpg', 'png', 'jpeg']) {
      final thumb = File('${_dir.path}/$vaultName.thumb.$ext');
      if (await thumb.exists()) {
        try {
          await thumb.delete();
        } catch (_) {}
      }
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

  LibraryFile toLibraryFile(VaultFile vf) {
    final dot = vf.name.lastIndexOf('.');
    final ext = dot > 0 ? vf.name.substring(dot + 1).toLowerCase() : '';
    return LibraryFile(
      filename: vf.name,
      title: dot > 0 ? vf.name.substring(0, dot) : vf.name,
      filePath: vf.path,
      fileSize: vf.size,
      fileSizeFormatted: StorageService.formatSize(vf.size),
      fileType: StorageService.fileTypeFor(ext),
      extension: ext,
      createdAt:
          DateTime.fromMillisecondsSinceEpoch(vf.modifiedMs).toIso8601String(),
      sourceType: 'downloaded',
    );
  }
}
