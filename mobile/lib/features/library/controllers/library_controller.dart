import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import '../../../data/models/library_file.dart';
import '../../../services/local_media_service.dart';
import '../../../services/storage_service.dart';
import '../../../services/media_metadata_service.dart';
import '../../../services/trash_service.dart';
import '../../../services/vault_service.dart';

enum LibraryFilter { all, videos, audio, favorites, history }

enum LibrarySort { dateNewest, dateOldest, nameAsc, nameDesc, sizeLargest, sizeSmallest }

enum LibraryViewMode { grid, list }

enum LibraryStatus { loading, loaded, permissionRequired, empty, error }

class LibraryController extends ChangeNotifier {
  final MediaMetadataService _meta;

  LibraryController({MediaMetadataService? meta})
      : _meta = meta ?? MediaMetadataService();

  List<LibraryFile> _allFiles = [];
  List<LibraryFile> get allFiles => List.unmodifiable(_allFiles);

  LibraryFilter _filter = LibraryFilter.all;
  LibraryFilter get filter => _filter;

  LibrarySort _sort = LibrarySort.dateNewest;
  LibrarySort get sort => _sort;

  LibraryViewMode _viewMode = LibraryViewMode.grid;
  LibraryViewMode get viewMode => _viewMode;

  String _searchQuery = '';
  String get searchQuery => _searchQuery;

  LibraryStatus _status = LibraryStatus.loading;
  LibraryStatus get status => _status;

  bool get loading => _status == LibraryStatus.loading;

  /// A refresh is running while the list is already on screen. The view shows
  /// this as a small progress indicator and disables the refresh button, so a
  /// second tap cannot start a second scan (the old one just looked dead).
  bool _refreshing = false;
  bool get refreshing => _refreshing;

  String? _errorKey;
  String? get errorKey => _errorKey;

  bool _permissionsGranted = false;
  bool get permissionsGranted => _permissionsGranted;

  MediaMetadataService get meta => _meta;

  /// The library is built from MediaStore AND from the app's own download
  /// folder. The same download is often present in both: MediaStore returns
  /// it keyed by `content://...` while the folder scan returns its filename,
  /// so the old merge produced two cards. Deleting one hid both because the
  /// delete action is by filename. Identity is the filename, not the URI.
  @visibleForTesting
  static List<LibraryFile> mergeUnique(
    Iterable<LibraryFile> deviceMedia,
    Iterable<LibraryFile> downloadedFiles,
  ) {
    final byName = <String, LibraryFile>{};

    void add(LibraryFile file) {
      final key = file.filename.trim().toLowerCase();
      if (key.isEmpty) return;
      final existing = byName[key];
      if (existing == null) {
        byName[key] = file;
        return;
      }
      // MediaStore entries have a contentUri and can be streamed on Android
      // 13+ without a storage path, so they win over a plain folder entry.
      if (file.hasContentUri && !existing.hasContentUri) {
        byName[key] = _enrich(file, existing);
      } else {
        byName[key] = _enrich(existing, file);
      }
    }

    for (final file in deviceMedia) {
      add(file);
    }
    for (final file in downloadedFiles) {
      add(file);
    }
    return byName.values.toList();
  }

  /// Keeps the playable entry and fills the fields only the other copy knows
  /// (embedded duration, sidecar thumbnail, artist...).
  static LibraryFile _enrich(LibraryFile primary, LibraryFile fallback) {
    return LibraryFile(
      filename: primary.filename,
      title: primary.title.trim().isEmpty ? fallback.title : primary.title,
      filePath:
          primary.filePath.isNotEmpty ? primary.filePath : fallback.filePath,
      fileSize: primary.fileSize > 0 ? primary.fileSize : fallback.fileSize,
      fileSizeFormatted: primary.fileSizeFormatted.isNotEmpty
          ? primary.fileSizeFormatted
          : fallback.fileSizeFormatted,
      fileType: primary.fileType != 'unknown'
          ? primary.fileType
          : fallback.fileType,
      extension:
          primary.extension.isNotEmpty ? primary.extension : fallback.extension,
      createdAt: primary.createdAt.isNotEmpty
          ? primary.createdAt
          : fallback.createdAt,
      thumbnail: primary.thumbnail ?? fallback.thumbnail,
      thumbnailPath: primary.thumbnailPath ?? fallback.thumbnailPath,
      source: primary.source ?? fallback.source,
      sourceType: primary.hasContentUri ? 'local' : primary.sourceType,
      contentUri: primary.contentUri ?? fallback.contentUri,
      album: primary.album ?? fallback.album,
      artist: primary.artist ?? fallback.artist,
      durationMs: primary.durationMs ?? fallback.durationMs,
    );
  }

  List<LibraryFile> get files {
    var result = List<LibraryFile>.from(_allFiles);

    switch (_filter) {
      case LibraryFilter.videos:
        result = result.where((f) => f.isVideo).toList();
        break;
      case LibraryFilter.audio:
        result = result.where((f) => f.isAudio).toList();
        break;
      case LibraryFilter.favorites:
        result = result.where((f) => _meta.isFavorite(f.filename)).toList();
        break;
      case LibraryFilter.history:
        return [];
      case LibraryFilter.all:
        break;
    }

    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      result = result.where((f) =>
        f.title.toLowerCase().contains(q) ||
        f.filename.toLowerCase().contains(q)
      ).toList();
    }

    switch (_sort) {
      case LibrarySort.dateNewest:
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case LibrarySort.dateOldest:
        result.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        break;
      case LibrarySort.nameAsc:
        result.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case LibrarySort.nameDesc:
        result.sort((a, b) => b.title.toLowerCase().compareTo(a.title.toLowerCase()));
        break;
      case LibrarySort.sizeLargest:
        result.sort((a, b) => b.fileSize.compareTo(a.fileSize));
        break;
      case LibrarySort.sizeSmallest:
        result.sort((a, b) => a.fileSize.compareTo(b.fileSize));
        break;
    }

    return result;
  }

  List<HistoryEntry> get history => _meta.history;

  void setFilter(LibraryFilter filter) {
    _filter = filter;
    notifyListeners();
  }

  void setSort(LibrarySort sort) {
    _sort = sort;
    notifyListeners();
  }

  void toggleViewMode() {
    _viewMode = _viewMode == LibraryViewMode.grid ? LibraryViewMode.list : LibraryViewMode.grid;
    notifyListeners();
  }

  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  Future<void> requestPermissions() async {
    final granted = await LocalMediaService.requestPermissions();
    _permissionsGranted = granted;
    if (granted) {
      await loadLibrary();
    } else {
      _status = LibraryStatus.permissionRequired;
      notifyListeners();
    }
  }

  Future<void> loadLibrary() async {
    if (_refreshing) return; // a second tap must not stack a second scan
    _refreshing = true;
    _errorKey = null;
    // Keep the current cards on screen while refreshing: replacing them with
    // a full-screen spinner on every refresh was why the button looked dead.
    if (_allFiles.isEmpty) _status = LibraryStatus.loading;
    notifyListeners();

    try {
      _permissionsGranted = await LocalMediaService.hasPermissions();
      if (!_permissionsGranted) {
        _status = LibraryStatus.permissionRequired;
        return;
      }

      // A finished download is not necessarily indexed yet: the downloads
      // screen asks MediaStore to scan it, but files written before this
      // version (or copied into the folder) never were.
      await _scanRecentDownloads();

      final deviceMedia = await LocalMediaService.getDeviceMedia();
      final downloadedFiles = await LocalMediaService.getDownloadedFiles();
      final existing = await _dropMissing(deviceMedia);

      _allFiles = mergeUnique(existing, downloadedFiles)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      await _loadThumbnailsFromMeta();
      _status = _allFiles.isEmpty ? LibraryStatus.empty : LibraryStatus.loaded;
      // Remote thumbnails are cosmetic: fetching them one by one before
      // notifying kept the refresh "loading" for the whole batch.
      unawaited(_migrateExistingThumbnails());
    } catch (e) {
      debugPrint('[LIBRARY] load failed: ${e.runtimeType} $e');
      _errorKey = 'errorFailedLoadLibrary';
      _status = LibraryStatus.error;
    } finally {
      _refreshing = false;
      notifyListeners();
    }
  }

  static const _appChannel = MethodChannel('com.example.vibegrab/app');

  /// Asks MediaStore to index the newest files of the download folder.
  ///
  /// Bounded to the 50 most recent: a full rescan of a big folder is exactly
  /// the kind of work that made "refresh" feel broken.
  Future<void> _scanRecentDownloads() async {
    try {
      final files = await StorageService.instance.listMediaFilesAsync();
      if (files.isEmpty) return;
      final paths = files.take(50).map((f) => f.path).toList();
      await _appChannel
          .invokeMethod('scanMedia', {'paths': paths})
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      // Not fatal: the folder listing right below still finds the files.
      debugPrint('[LIBRARY] scanMedia failed: ${e.runtimeType}');
    }
  }

  /// Drops MediaStore rows whose file no longer exists. A stale index would
  /// keep showing cards that cannot be played or deleted.
  Future<List<LibraryFile>> _dropMissing(List<LibraryFile> entries) async {
    final result = <LibraryFile>[];
    for (final file in entries) {
      if (file.filePath.isEmpty) {
        result.add(file);
        continue;
      }
      try {
        if (await File(file.filePath).exists()) result.add(file);
      } catch (_) {
        result.add(file);
      }
    }
    return result;
  }

  static LibraryFile _copyWith(
    LibraryFile f, {
    String? title,
    String? thumbnail,
    String? thumbnailPath,
    String? source,
  }) =>
      LibraryFile(
        filename: f.filename,
        title: title ?? f.title,
        filePath: f.filePath,
        fileSize: f.fileSize,
        fileSizeFormatted: f.fileSizeFormatted,
        fileType: f.fileType,
        extension: f.extension,
        createdAt: f.createdAt,
        thumbnail: thumbnail ?? f.thumbnail,
        thumbnailPath: thumbnailPath ?? f.thumbnailPath,
        source: source ?? f.source,
        sourceType: f.sourceType,
        contentUri: f.contentUri,
        album: f.album,
        artist: f.artist,
        durationMs: f.durationMs,
      );

  Future<void> _loadThumbnailsFromMeta() async {
    final storage = StorageService.instance;
    for (var i = 0; i < _allFiles.length; i++) {
      final file = _allFiles[i];
      if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
        continue;
      }

      final baseName = file.filename.contains('.')
          ? file.filename.substring(0, file.filename.lastIndexOf('.'))
          : file.filename;

      final foundLocalThumb = await storage.getThumbFileAsync(baseName);

      String? thumbUrl = file.thumbnail;
      String? title;
      String? source;

      final metaFile = storage.getFile('$baseName.meta.json');
      if (metaFile != null && await metaFile.exists()) {
        try {
          final decoded = jsonDecode(await metaFile.readAsString());
          if (decoded is Map<String, dynamic>) {
            thumbUrl = decoded['thumbnail'] as String? ?? thumbUrl;
            title = decoded['title'] as String?;
            source = decoded['source'] as String?;
          }
        } catch (_) {
          // A corrupt sidecar must not hide the media file itself.
        }
      }

      final hasRemoteThumb = thumbUrl != null && thumbUrl.isNotEmpty;
      if (foundLocalThumb == null && !hasRemoteThumb &&
          title == null && source == null) {
        continue;
      }

      _allFiles[i] = _copyWith(
        file,
        title: title ?? file.title,
        thumbnail: foundLocalThumb == null ? thumbUrl : file.thumbnail,
        thumbnailPath: foundLocalThumb?.path,
        source: source ?? file.source,
      );
    }
  }

  bool _thumbMigrationRunning = false;

  Future<void> _migrateExistingThumbnails() async {
    if (_thumbMigrationRunning) return;
    _thumbMigrationRunning = true;
    final client = HttpClient();
    var changed = false;
    try {
      for (final file in List<LibraryFile>.from(_allFiles)) {
        if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) {
          continue;
        }
        final url = file.thumbnail;
        if (url == null || url.isEmpty || !url.startsWith('http')) continue;

        final baseName = file.filename.contains('.')
            ? file.filename.substring(0, file.filename.lastIndexOf('.'))
            : file.filename;
        final existingJpg =
            await StorageService.instance.getThumbFileAsync(baseName);
        if (existingJpg != null) {
          _setThumb(file.filename, existingJpg.path);
          changed = true;
          continue;
        }

        try {
          final request = await client.getUrl(Uri.parse(url));
          request.headers.set('User-Agent', 'Mozilla/5.0');
          final response =
              await request.close().timeout(const Duration(seconds: 10));
          if (response.statusCode == 200) {
            final bytes = await response.fold<List<int>>(
                [], (prev, chunk) => prev..addAll(chunk));
            final jpgPath = '${StorageService.instance.thumbDir.path}'
                '${Platform.pathSeparator}$baseName.jpg';
            await File(jpgPath).writeAsBytes(bytes);
            _setThumb(file.filename, jpgPath);
            changed = true;
          }
        } catch (e) {
          debugPrint('[LIBRARY] thumb fetch failed: ${e.runtimeType}');
        }
      }
    } finally {
      client.close(force: true);
      _thumbMigrationRunning = false;
      if (changed) notifyListeners();
    }
  }

  void _setThumb(String filename, String path) {
    final idx = _allFiles.indexWhere((f) => f.filename == filename);
    if (idx == -1) return;
    _allFiles[idx] = _copyWith(_allFiles[idx], thumbnailPath: path);
  }

  Future<void> deleteFile(String filename) async {
    try {
      final entry = await TrashService.instance.moveToTrash(filename);
      if (entry == null) {
        // The file was not moved: keep it in the library and surface the
        // failure instead of pretending it went to the trash.
        _errorKey = 'errorFailedDeleteFile';
        notifyListeners();
        return;
      }
      _allFiles.removeWhere((f) => f.filename == filename);
      // Keep the metadata (favorite, resume position) so restoring the file
      // brings those back. Only the history entry is hidden while trashed.
      await _meta.removeHistoryEntry(filename);
      if (_allFiles.isEmpty) {
        _status = LibraryStatus.empty;
      }
      notifyListeners();
    } catch (e) {
      _errorKey = 'errorFailedDeleteFile';
      notifyListeners();
    }
  }

  Future<bool> vaultFile(String filename) async {
    try {
      final moved = await VaultService.instance.moveToVault(filename);
      if (moved == null) return false;
      _allFiles.removeWhere((f) => f.filename == filename);
      await _meta.removeFileData(filename);
      if (_allFiles.isEmpty) {
        _status = LibraryStatus.empty;
      }
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> toggleFavorite(String filename) async {
    await _meta.toggleFavorite(filename);
    notifyListeners();
  }

  /// Permanent deletion (skips the trash). Used by the "delete forever"
  /// action in the library overflow menu.
  Future<bool> deletePermanently(String filename) async {
    try {
      final file = findFile(filename);
      if (file == null) return false;

      var deleted = false;
      // MediaStore-owned entries (Android 13+ may not expose a writable
      // path) must be removed through the platform, not with a path delete
      // on a file that no longer has one.
      final uri = file.contentUri;
      if (uri != null && uri.isNotEmpty) {
        deleted = await StorageService.instance.deleteMedia(uri);
        if (!deleted) {
          _logDeleteFailure(filename, 'platform refused the content URI');
        }
      }
      if (!deleted) {
        deleted = StorageService.instance.deleteFile(filename);
      }
      if (!deleted && file.filePath.isNotEmpty) {
        try {
          final absolute = File(file.filePath);
          if (await absolute.exists()) {
            await absolute.delete();
            deleted = true;
          }
        } catch (e) {
          _logDeleteFailure(filename, e.runtimeType.toString());
        }
      }
      if (!deleted) {
        // Do NOT remove the card for a file that is still there: the next
        // refresh would bring it back and the user thinks the delete failed
        // silently. Report it instead.
        _errorKey = 'errorFailedDeleteFile';
        notifyListeners();
        return false;
      }

      // Sidecars of a deleted file are garbage; best effort.
      final baseName = filename.contains('.')
          ? filename.substring(0, filename.lastIndexOf('.'))
          : filename;
      try {
        final sidecar = StorageService.instance.getFile('$baseName.meta.json');
        if (sidecar != null && await sidecar.exists()) {
          await sidecar.delete();
        }
        final thumb =
            await StorageService.instance.getThumbFileAsync(baseName);
        if (thumb != null) await thumb.delete();
      } catch (_) {}

      await _meta.removeFileData(filename);
      _allFiles.removeWhere((f) => f.filename == filename);
      if (_allFiles.isEmpty) _status = LibraryStatus.empty;
      notifyListeners();
      return true;
    } catch (e) {
      _logDeleteFailure(filename, e.runtimeType.toString());
      _errorKey = 'errorFailedDeleteFile';
      notifyListeners();
      return false;
    }
  }

  void _logDeleteFailure(String filename, String cause) {
    // The filename is the user's own content, not a secret, but keep the log
    // compact: the reason is what matters.
    debugPrint('[LIBRARY] permanent delete failed: $cause');
  }

  /// Removes one entry from the play history (the file is untouched).
  Future<void> removeFromHistory(String filename) async {
    await _meta.removeHistoryEntry(filename);
    notifyListeners();
  }

  /// Clears the whole play history.
  Future<void> clearHistory() async {
    await _meta.clearHistory();
    notifyListeners();
  }

  LibraryFile? findFile(String filename) {
    try {
      return _allFiles.firstWhere((f) => f.filename == filename);
    } catch (_) {
      return null;
    }
  }
}
