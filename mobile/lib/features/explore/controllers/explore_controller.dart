import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/connectivity_service.dart';

enum ExploreError { none, noInternet, backendUnavailable, noResults, searchFailed }

enum ExploreTab { trending, categories }

class ExploreController extends ChangeNotifier {
  final LocalExtractionService _extraction;

  ExploreController({LocalExtractionService? extraction})
      : _extraction = extraction ?? LocalExtractionService();

  List<ExploreVideo> _videos = [];
  List<ExploreVideo> get results => List.unmodifiable(_videos);

  List<ExploreVideo> _trending = [];
  List<ExploreVideo> get trending => List.unmodifiable(_trending);

  bool _loading = false;
  bool get isLoading => _loading;

  bool _trendingLoading = false;
  bool get trendingLoading => _trendingLoading;

  ExploreError _exploreError = ExploreError.none;
  ExploreError get exploreError => _exploreError;

  String? _error;
  String? get error => _error;

  String _query = '';
  String get query => _query;

  ExploreTab _activeTab = ExploreTab.trending;
  ExploreTab get activeTab => _activeTab;

  String? _selectedCategory;
  String? get selectedCategory => _selectedCategory;

  List<ExploreVideo> _categoryResults = [];
  List<ExploreVideo> get categoryResults => List.unmodifiable(_categoryResults);

  bool _categoryLoading = false;
  bool get categoryLoading => _categoryLoading;

  List<String> _recentSearches = [];
  List<String> get recentSearches => List.unmodifiable(_recentSearches);

  Timer? _debounce;
  static const _recentKey = 'vibegrab_recent_searches';

  List<String> get categories => LocalExtractionService.categories;

  Future<void> init() async {
    await _loadRecentSearches();
    await loadTrending();
  }

  Future<void> loadTrending() async {
    if (_trendingLoading) return;
    _trendingLoading = true;
    _exploreError = ExploreError.none;
    notifyListeners();

    try {
      if (!ConnectivityService.instance.hasInternet) {
        _trendingLoading = false;
        _exploreError = ExploreError.noInternet;
        notifyListeners();
        return;
      }
      const queries = LocalExtractionService.trendingQueries;
      final futures = [
        for (final q in queries.take(3))
          () async {
            try {
              return await _extraction.search(q, limit: 12);
            } catch (e) {
              debugPrint('Trending query "$q" failed: $e');
              return <ExploreVideo>[];
            }
          }(),
      ];
      final batches = await Future.wait(futures);
      final merged = <ExploreVideo>[];
      final seenIds = <String>{};
      for (final batch in batches) {
        for (final video in batch) {
          if (video.id.isNotEmpty && seenIds.add(video.id)) {
            merged.add(video);
          }
        }
      }
      _trending = merged.take(12).toList();
      if (_trending.isEmpty) {
        try {
          _trending = await _extraction.search('popular music', limit: 12);
        } catch (_) {}
      }
      if (_trending.isEmpty) {
        try {
          _trending = await _extraction.search('music', limit: 12);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Trending load error: $e');
      try {
        _trending = await _extraction.search('music', limit: 12);
      } catch (_) {}
    } finally {
      _trendingLoading = false;
      notifyListeners();
    }
  }

  void setTab(ExploreTab tab) {
    _activeTab = tab;
    notifyListeners();
  }

  Future<void> selectCategory(String category) async {
    _selectedCategory = category;
    _categoryLoading = true;
    _categoryResults = [];
    notifyListeners();

    try {
      if (!ConnectivityService.instance.hasInternet) {
        _categoryLoading = false;
        notifyListeners();
        return;
      }
      _categoryResults = await _extraction.searchCategory(category, limit: 8);
    } catch (_) {} finally {
      _categoryLoading = false;
      notifyListeners();
    }
  }

  void clearCategory() {
    _selectedCategory = null;
    _categoryResults = [];
    notifyListeners();
  }

  Future<void> _loadRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_recentKey);
      _recentSearches = raw ?? [];
    } catch (_) {
      _recentSearches = [];
    }
    notifyListeners();
  }

  Future<void> _saveRecentSearches() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_recentKey, _recentSearches);
    } catch (_) {}
  }

  void _addRecentSearch(String query) {
    _recentSearches.remove(query);
    _recentSearches.insert(0, query);
    if (_recentSearches.length > 20) {
      _recentSearches = _recentSearches.sublist(0, 20);
    }
    _saveRecentSearches();
  }

  void removeRecentSearch(String query) {
    _recentSearches.remove(query);
    _saveRecentSearches();
    notifyListeners();
  }

  void clearRecentSearches() {
    _recentSearches.clear();
    _saveRecentSearches();
    notifyListeners();
  }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) return;
    _query = query.trim();
    _loading = true;
    _exploreError = ExploreError.none;
    _error = null;
    _activeTab = ExploreTab.trending;
    notifyListeners();

    try {
      if (!ConnectivityService.instance.hasInternet) {
        _exploreError = ExploreError.noInternet;
        _error = null;
        _loading = false;
        notifyListeners();
        return;
      }

      _videos = await _extraction.search(_query);
      _addRecentSearch(_query);
      if (_videos.isEmpty) {
        _exploreError = ExploreError.noResults;
      }
    } catch (e) {
      _exploreError = ExploreError.searchFailed;
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void searchImmediate(String query) {
    _debounce?.cancel();
    search(query);
  }

  void searchDebounced(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      search(query);
    });
  }

  void clearResults() {
    _videos = [];
    _query = '';
    _exploreError = ExploreError.none;
    _error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
