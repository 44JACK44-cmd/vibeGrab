import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
    _status = LibraryStatus.loading;
    _errorKey = null;
    notifyListeners();

    try {
      _permissionsGranted = await LocalMediaService.hasPermissions();
      if (!_permissionsGranted) {
        _status = LibraryStatus.permissionRequired;
        notifyListeners();
        return;
      }

      final deviceMedia = await LocalMediaService.getDeviceMedia();
      final downloadedFiles = LocalMediaService.getDownloadedFiles();

      _allFiles = mergeUnique(deviceMedia, downloadedFiles)
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      _loadThumbnailsFromMeta();
      _migrateExistingThumbnails();

      _status = _allFiles.isEmpty ? LibraryStatus.empty : LibraryStatus.loaded;
    } catch (e) {
      _errorKey = 'errorFailedLoadLibrary';
      _status = LibraryStatus.error;
    } finally {
      notifyListeners();
    }
  }

  void _loadThumbnailsFromMeta() {
    final storage = StorageService.instance;
    for (var i = 0; i < _allFiles.length; i++) {
      final file = _allFiles[i];

      final baseName = file.filename.contains('.')
          ? file.filename.substring(0, file.filename.lastIndexOf('.'))
          : file.filename;

      final foundLocalThumb = storage.getThumbFile(baseName);

      if (file.thumbnail != null && file.thumbnail!.isNotEmpty && file.thumbnailPath != null) {
        if (foundLocalThumb != null && foundLocalThumb.existsSync()) continue;
      }

      final metaPath = '$baseName.meta.json';
      final metaFile = storage.getFile(metaPath);

      String? thumbUrl;
      String? thumbPath;
      String? title;
      String? source;

      if (foundLocalThumb != null && foundLocalThumb.existsSync()) {
        thumbPath = foundLocalThumb.path;
      }

      if (metaFile != null && metaFile.existsSync()) {
        try {
          final content = metaFile.readAsStringSync();
          final meta = jsonDecode(content) as Map<String, dynamic>;
          thumbUrl = meta['thumbnail'] as String?;
          title = meta['title'] as String?;
          source = meta['source'] as String?;
        } catch (_) {}
      }

      if (thumbPath != null || (thumbUrl != null && thumbUrl.isNotEmpty)) {
        _allFiles[i] = LibraryFile(
          filename: file.filename,
          title: title ?? file.title,
          filePath: file.filePath,
          fileSize: file.fileSize,
          fileSizeFormatted: file.fileSizeFormatted,
          fileType: file.fileType,
          extension: file.extension,
          createdAt: file.createdAt,
          thumbnail: thumbPath == null ? thumbUrl : file.thumbnail,
          thumbnailPath: thumbPath,
          source: source ?? file.source,
          sourceType: file.sourceType,
          contentUri: file.contentUri,
          album: file.album,
          artist: file.artist,
          durationMs: file.durationMs,
        );
      }
    }
  }

  Future<void> _migrateExistingThumbnails() async {
    final storage = StorageService.instance;
    for (final file in _allFiles) {
      if (file.thumbnailPath != null && file.thumbnailPath!.isNotEmpty) continue;
      if (file.thumbnail == null || file.thumbnail!.isEmpty) continue;

      final baseName = file.filename.contains('.')
          ? file.filename.substring(0, file.filename.lastIndexOf('.'))
          : file.filename;
      final existingJpg = storage.getThumbFile(baseName);
      if (existingJpg != null && existingJpg.existsSync()) continue;

      final url = file.thumbnail!;
      try {
        final request = await HttpClient().getUrl(Uri.parse(url));
        request.headers.set('User-Agent', 'Mozilla/5.0');
        final response = await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
          final jpgPath = '${storage.thumbDir.path}${Platform.pathSeparator}$baseName.jpg';
          await File(jpgPath).writeAsBytes(bytes);
          final idx = _allFiles.indexWhere((f) => f.filename == file.filename);
          if (idx != -1) {
            _allFiles[idx] = LibraryFile(
              filename: file.filename,
              title: file.title,
              filePath: file.filePath,
              fileSize: file.fileSize,
              fileSizeFormatted: file.fileSizeFormatted,
              fileType: file.fileType,
              extension: file.extension,
              createdAt: file.createdAt,
              thumbnail: file.thumbnail,
              thumbnailPath: jpgPath,
              source: file.source,
              sourceType: file.sourceType,
              contentUri: file.contentUri,
              album: file.album,
              artist: file.artist,
              durationMs: file.durationMs,
            );
          }
        }
      } catch (_) {}
    }
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
      if (file != null) {
        final path = file.filePath.isNotEmpty
            ? file.filePath
            : file.contentUri ?? '';
        if (path.isNotEmpty) {
          StorageService.instance.deleteFile(filename);
        }
      }
      await _meta.removeFileData(filename);
      _allFiles.removeWhere((f) => f.filename == filename);
      if (_allFiles.isEmpty) _status = LibraryStatus.empty;
      notifyListeners();
      return true;
    } catch (e) {
      _errorKey = 'errorFailedDeleteFile';
      notifyListeners();
      return false;
    }
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
