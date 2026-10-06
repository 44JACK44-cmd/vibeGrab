import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/connectivity_service.dart';
import '../../../services/media_metadata_service.dart';

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

  Map<String, List<String>> get categoryGroups =>
      LocalExtractionService.categoryGroups;

  List<ExploreVideo> _forYou = [];
  List<ExploreVideo> get forYou => List.unmodifiable(_forYou);
  bool _forYouLoading = false;
  bool get forYouLoading => _forYouLoading;

  List<ExploreVideo> _shorts = [];
  List<ExploreVideo> get shorts => List.unmodifiable(_shorts);
  bool _shortsLoading = false;
  bool get shortsLoading => _shortsLoading;

  bool _loadingMore = false;
  bool get loadingMore => _loadingMore;

  bool _searchExhausted = false;
  bool get searchExhausted => _searchExhausted;

  bool _categoryExhausted = false;
  bool get categoryExhausted => _categoryExhausted;

  /// Ids shown in this session (trending/for-you): used to avoid repeating
  /// the same videos on every refresh when alternatives exist.
  final Set<String> _recentlyShown = <String>{};
  final List<String> _recentlyShownOrder = <String>[];

  void _rememberShown(Iterable<ExploreVideo> videos) {
    for (final v in videos) {
      if (v.id.isEmpty) continue;
      if (_recentlyShown.add(v.id)) _recentlyShownOrder.add(v.id);
    }
    while (_recentlyShownOrder.length > 120) {
      _recentlyShown.remove(_recentlyShownOrder.removeAt(0));
    }
  }

  List<ExploreVideo> _preferUnseen(List<ExploreVideo> videos) {
    final fresh = videos.where((v) => !_recentlyShown.contains(v.id)).toList();
    return fresh.isNotEmpty ? fresh : videos;
  }

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
      // Progressive: rotate the query order every refresh, show the first
      // batch immediately and append the rest as they arrive instead of
      // blocking the whole UI on every query.
      final queries = List<String>.from(LocalExtractionService.trendingQueries)
        ..shuffle();
      final merged = <ExploreVideo>[];
      final seenIds = <String>{};
      var first = true;
      for (final q in queries.take(3)) {
        List<ExploreVideo> batch = const [];
        try {
          batch = await _extraction.search(q, limit: 12);
        } catch (e) {
          debugPrint('Trending query "$q" failed: $e');
        }
        for (final video in batch) {
          if (video.id.isNotEmpty && seenIds.add(video.id)) {
            merged.add(video);
          }
        }
        if (first) {
          first = false;
          _trending = _preferUnseen(merged).take(12).toList();
          _rememberShown(_trending);
          _trendingLoading = false;
          notifyListeners();
        }
      }
      _trending = _preferUnseen(merged).take(12).toList();
      _rememberShown(_trending);
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

  /// Appends the next page of the current search (infinite scroll).
  Future<void> loadMoreResults() async {
    if (_loadingMore || _query.isEmpty || _searchExhausted) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final more = await _extraction.searchMore(_query, limit: 10);
      if (more.isEmpty) {
        _searchExhausted = true;
      } else {
        final seen = _videos.map((e) => e.id).toSet();
        for (final v in more) {
          if (seen.add(v.id)) _videos.add(v);
        }
      }
    } catch (_) {
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// Appends the next page of the current category.
  Future<void> loadMoreCategory() async {
    final cat = _selectedCategory;
    if (_loadingMore || cat == null || _categoryExhausted) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final more = await _extraction.searchMore('$cat popular', limit: 8);
      if (more.isEmpty) {
        _categoryExhausted = true;
      } else {
        final seen = _categoryResults.map((e) => e.id).toSet();
        for (final v in more) {
          if (seen.add(v.id)) _categoryResults.add(v);
        }
      }
    } catch (_) {
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  /// "Para ti": 70% intereses (búsquedas + historial), 20% novedad
  /// (tendencias rotadas), 10% descubrimiento (categoría al azar). Contenido
  /// real en todos los casos; sin burbuja cerrada.
  Future<void> loadForYou() async {
    if (_forYouLoading) return;
    _forYouLoading = true;
    notifyListeners();
    try {
      if (!ConnectivityService.instance.hasInternet) {
        _forYouLoading = false;
        notifyListeners();
        return;
      }
      final interests = _interestKeywords();
      final fresh = <ExploreVideo>[];
      final seen = <String>{};
      void absorb(List<ExploreVideo> batch) {
        for (final v in batch) {
          if (v.id.isNotEmpty && seen.add(v.id)) fresh.add(v);
        }
      }

      for (final kw in interests.take(3)) {
        if (fresh.length >= 10) break;
        try {
          absorb(await _extraction.search('$kw music', limit: 6));
        } catch (_) {}
      }
      final rotating =
          List<String>.from(LocalExtractionService.trendingQueries)..shuffle();
      for (final q in rotating.take(2)) {
        if (fresh.length >= 14) break;
        try {
          absorb(await _extraction.search(q, limit: 6));
        } catch (_) {}
      }
      try {
        final cats = List<String>.from(LocalExtractionService.categories)
          ..shuffle();
        if (fresh.length < 16 && cats.isNotEmpty) {
          absorb(await _extraction.searchCategory(cats.first, limit: 4));
        }
      } catch (_) {}
      _forYou = _preferUnseen(fresh).take(12).toList();
      _rememberShown(_forYou);
    } finally {
      _forYouLoading = false;
      notifyListeners();
    }
  }

  Future<void> loadShorts() async {
    if (_shortsLoading) return;
    _shortsLoading = true;
    notifyListeners();
    try {
      if (!ConnectivityService.instance.hasInternet) {
        _shortsLoading = false;
        notifyListeners();
        return;
      }
      final interests = _interestKeywords();
      final queries = <String>[
        if (interests.isNotEmpty) '${interests.first} shorts',
        'shorts music videos',
        'shorts comedia',
      ];
      final out = <ExploreVideo>[];
      final seen = <String>{};
      for (final q in queries) {
        if (out.length >= 15) break;
        try {
          final r = await _extraction.searchShorts(q, limit: 8);
          for (final v in r) {
            if (v.id.isNotEmpty && seen.add(v.id)) out.add(v);
          }
        } catch (_) {}
      }
      _shorts = _preferUnseen(out);
      _rememberShown(_shorts);
    } finally {
      _shortsLoading = false;
      notifyListeners();
    }
  }

  /// Top keywords from recent searches + play history (stopwords removed).
  List<String> _interestKeywords() {
    final counts = <String, int>{};
    void addText(String? text) {
      if (text == null) return;
      for (final w
          in text.toLowerCase().split(RegExp(r'[^a-záéíóúñü0-9]+'))) {
        if (w.length < 4 || _stopwords.contains(w)) continue;
        counts[w] = (counts[w] ?? 0) + 1;
      }
    }

    for (final q in _recentSearches.take(10)) {
      addText(q);
    }
    try {
      for (final h in MediaMetadataService().history.take(30)) {
        addText(h.title);
      }
    } catch (_) {}
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(3).map((e) => e.key).toList();
  }

  static const _stopwords = {
    'para', 'por', 'con', 'los', 'las', 'una', 'unos', 'unas', 'este',
    'esta', 'esto', 'desde', 'hasta', 'sobre', 'entre', 'como', 'pero',
    'sus', 'que', 'del', 'the', 'and', 'for', 'with', 'from', 'that',
    'this', 'music', 'video', 'videos', 'song', 'songs', 'official',
    'musica', 'música',
  };

  void setTab(ExploreTab tab) {
    _activeTab = tab;
    notifyListeners();
  }

  Future<void> selectCategory(String category) async {
    _selectedCategory = category;
    _categoryLoading = true;
    _categoryResults = [];
    _categoryExhausted = false;
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
    _searchExhausted = false;
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
