import 'dart:io';
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

      final merged = <String, LibraryFile>{};

      for (final f in deviceMedia) {
        final key = f.hasContentUri ? (f.contentUri ?? f.filename) : f.filename;
        merged[key] = f;
      }

      for (final f in downloadedFiles) {
        if (!merged.containsKey(f.filename)) {
          merged[f.filename] = f;
        }
      }

      _allFiles = merged.values.toList()
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

      final localThumb = storage.getFile('$baseName.jpg');
      final localThumbPng = storage.getFile('$baseName.png');
      final localThumbJpeg = storage.getFile('$baseName.jpeg');
      final foundLocalThumb = localThumb ?? localThumbPng ?? localThumbJpeg;

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
      final existingJpg = storage.getFile('$baseName.jpg');
      if (existingJpg != null && existingJpg.existsSync()) continue;

      final url = file.thumbnail!;
      try {
        final request = await HttpClient().getUrl(Uri.parse(url));
        request.headers.set('User-Agent', 'Mozilla/5.0');
        final response = await request.close().timeout(const Duration(seconds: 10));
        if (response.statusCode == 200) {
          final bytes = await response.fold<List<int>>([], (prev, chunk) => prev..addAll(chunk));
          final jpgPath = '${storage.downloadPath}${Platform.pathSeparator}$baseName.jpg';
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
      await TrashService.instance.moveToTrash(filename);
      _allFiles.removeWhere((f) => f.filename == filename);
      await _meta.removeFileData(filename);
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

  LibraryFile? findFile(String filename) {
    try {
      return _allFiles.firstWhere((f) => f.filename == filename);
    } catch (_) {
      return null;
    }
  }
}
