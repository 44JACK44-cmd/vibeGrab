import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/explore_search_page.dart';
import '../../../data/models/explore_video.dart';
import '../../../services/api_service.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/connectivity_service.dart';
import '../../../services/media_metadata_service.dart';
import '../../../services/media_provider_resolver.dart';

enum ExploreError { none, noInternet, backendUnavailable, noResults, searchFailed }

enum ExploreTab { trending, categories }

class ExploreController extends ChangeNotifier {
  final LocalExtractionService _extraction;
  final ApiService _api;

  ExploreController({LocalExtractionService? extraction, ApiService? api})
      : _extraction = extraction ?? LocalExtractionService(),
        _api = api ?? ApiService();

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

  // --- Search ordering (server side: relevance / views + date window) ---
  String _sort = 'relevance';
  String get sort => _sort;
  String _when = 'any';
  String get when => _when;
  int _searchPage = 0;
  int _categoryPage = 0;
  bool _serverSearchFailed = false;
  int _searchSeq = 0;

  // --- Continue watching (resume points of remote videos) ---
  List<ExploreVideo> _continueWatching = [];
  List<ExploreVideo> get continueWatching => List.unmodifiable(_continueWatching);

  // --- Home rails: one real result list per category, loaded lazily ---
  final Map<String, List<ExploreVideo>> _rails = {};
  bool _railsLoading = false;
  bool get railsLoading => _railsLoading;
  List<String> get railKeys => _rails.keys.toList(growable: false);
  List<ExploreVideo> rail(String key) =>
      List.unmodifiable(_rails[key] ?? const <ExploreVideo>[]);

  // --- Pasted link resolution ---
  PastedLinkResult? _linkResult;
  PastedLinkResult? get linkResult => _linkResult;
  bool _linkLoading = false;
  bool get linkLoading => _linkLoading;
  String? _linkError;
  String? get linkError => _linkError;

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

  /// Server search (innertube on the backend) with automatic local fallback.
  /// Returns null when the server could not answer, so the caller can switch
  /// to the on-device youtube_explode search instead of failing.
  Future<ExploreSearchPage?> _serverSearch(
    String query, {
    int limit = 12,
    int page = 1,
    String? order,
    String? window,
  }) async {
    if (!ConnectivityService.instance.hasInternet) return null;
    try {
      return await _api.searchExplore(
        query,
        limit: limit,
        page: page,
        sort: order ?? _sort,
        when: window ?? _when,
      );
    } catch (e) {
      debugPrint('[Explore] server search failed for "$query": $e');
      return null;
    }
  }

  void _appendUnique(List<ExploreVideo> target, List<ExploreVideo> items) {
    final seen = target.map((e) => e.id).toSet();
    for (final v in items) {
      if (v.id.isNotEmpty && seen.add(v.id)) target.add(v);
    }
  }

  String _keyOf(ExploreVideo v) => v.id.isNotEmpty ? v.id : v.url;

  /// Removes repeats inside [items] by id (or url when the id is empty) AND
  /// by url, so list keys stay unique and no card is shown twice.
  List<ExploreVideo> _dedupe(Iterable<ExploreVideo> items) {
    final ids = <String>{};
    final urls = <String>{};
    final out = <ExploreVideo>[];
    for (final v in items) {
      final idOk = v.id.isEmpty || ids.add(v.id);
      final urlOk = v.url.isEmpty || urls.add(v.url);
      if (idOk && urlOk) out.add(v);
    }
    return out;
  }

  /// Keys already displayed in other home sections. Used so every new
  /// section (for-you, rails, "all results") only adds videos not yet seen.
  Set<String> _homeIds({
    bool continueWatching = false,
    bool trending = false,
    bool forYou = false,
    bool rails = false,
  }) {
    final s = <String>{};
    if (continueWatching) {
      for (final v in _continueWatching) s.add(_keyOf(v));
    }
    if (trending) {
      for (final v in _trending) s.add(_keyOf(v));
    }
    if (forYou) {
      for (final v in _forYou) s.add(_keyOf(v));
    }
    if (rails) {
      for (final list in _rails.values) {
        for (final v in list) s.add(_keyOf(v));
      }
    }
    return s;
  }

  Future<void> init() async {
    await _loadRecentSearches();
    // Instant feed: show the last session's feed immediately (if any) and
    // refresh trending + continue-watching in parallel, never serially.
    final cached = await _loadFeedCache();
    if (cached) notifyListeners();
    await Future.wait([
      loadContinueWatching(),
      loadTrending(),
    ]);
  }

  // --- Feed cache: the home screen renders from disk while the network
  // refreshes in the background (Render cold starts can take ~40s).

  static const _feedCacheKey = 'explore_feed_cache_v1';

  Future<void> _saveFeedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = <String, dynamic>{
        'trending': _trending.map((v) => v.toJson()).toList(),
        'forYou': _forYou.map((v) => v.toJson()).toList(),
        'rails': {
          for (final e in _rails.entries)
            e.key: e.value.map((v) => v.toJson()).toList(),
        },
      };
      await prefs.setString(_feedCacheKey, jsonEncode(data));
    } catch (_) {}
  }

  Future<bool> _loadFeedCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_feedCacheKey);
      if (raw == null || raw.isEmpty) return false;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      List<ExploreVideo> decode(Object? raw) => ((raw ?? const []) as List)
          .whereType<Map<String, dynamic>>()
          .map(ExploreVideo.fromJson)
          .toList();

      final trending = _dedupe(decode(data['trending']));
      final forYou = _dedupe(decode(data['forYou']));
      final railsRaw =
          ((data['rails'] ?? const {}) as Map<String, dynamic>);
      final rails = <String, List<ExploreVideo>>{};
      railsRaw.forEach((key, value) {
        final list = _dedupe(decode(value));
        if (list.isNotEmpty) rails[key] = list;
      });

      if (trending.isEmpty && forYou.isEmpty && rails.isEmpty) return false;
      if (trending.isNotEmpty) _trending = trending;
      _forYou = forYou;
      _rails
        ..clear()
        ..addAll(rails);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Videos with a saved position: the "continue watching" rail.
  Future<void> loadContinueWatching() async {
    try {
      final svc = MediaMetadataService();
      final out = <ExploreVideo>[];
      for (final h in svc.history) {
        if (!h.filename.startsWith('http')) continue;
        final meta = svc.getMeta(h.filename);
        if (!meta.hasResume) continue;
        out.add(ExploreVideo(
          id: YouTubeProvider.extractVideoId(h.filename) ?? h.filename,
          title: h.title,
          url: h.filename,
          thumbnail: h.thumbnail,
          channel: h.source,
          provider: 'youtube',
          resumeMs: meta.lastPositionMs,
          duration: meta.durationMs > 0 ? (meta.durationMs / 1000).round() : null,
        ));
        if (out.length >= 6) break;
      }
      if (out.length != _continueWatching.length ||
          out.any((v) => !_continueWatching.any((c) => c.url == v.url))) {
        _continueWatching = out;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[Explore] continue watching load failed: $e');
    }
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

      // 1) One server round trip gives a live, most-viewed feed.
      try {
        final live = await _api.fetchTrending(limit: 20);
        if (live.isNotEmpty) {
          final excluded = _homeIds(continueWatching: true);
          _trending = _dedupe(_preferUnseen(live)
                  .where((v) => !excluded.contains(_keyOf(v))))
              .take(14)
              .toList();
          _rememberShown(_trending);
          _trendingLoading = false;
          notifyListeners();
        }
      } catch (e) {
        debugPrint('[Explore] trending endpoint failed: $e');
      }
      if (_trending.isNotEmpty) return;

      // 2) Fallback: rotate real search queries, show the first batch as
      // soon as it lands instead of blocking the whole UI on every query.
      final queries = List<String>.from(LocalExtractionService.trendingQueries)
        ..shuffle();
      final merged = <ExploreVideo>[];
      final seenIds = <String>{};
      final excluded = _homeIds(continueWatching: true);
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
          _trending = _dedupe(_preferUnseen(merged)
                  .where((v) => !excluded.contains(_keyOf(v))))
              .take(12)
              .toList();
          _rememberShown(_trending);
          _trendingLoading = false;
          notifyListeners();
        }
      }
      _trending = _dedupe(_preferUnseen(merged)
              .where((v) => !excluded.contains(_keyOf(v))))
          .take(12)
          .toList();
      _rememberShown(_trending);
      if (_trending.isEmpty) {
        try {
          _trending =
              _dedupe(await _extraction.search('popular music', limit: 12));
        } catch (_) {}
      }
      if (_trending.isEmpty) {
        try {
          _trending = _dedupe(await _extraction.search('music', limit: 12));
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('Trending load error: $e');
      try {
        _trending = _dedupe(await _extraction.search('music', limit: 12));
      } catch (_) {}
    } finally {
      _trendingLoading = false;
      notifyListeners();
      _saveFeedCache();
    }
  }

  /// Home rails (one per category), loaded progressively so the first row
  /// appears without waiting for the rest. All missing rails are requested
  /// CONCURRENTLY — serial requests made the feed feel frozen.
  Future<void> loadRails({int count = 4}) async {
    if (_railsLoading) return;
    _railsLoading = true;
    notifyListeners();
    try {
      final wanted = LocalExtractionService.categories
          .where((c) => !_rails.containsKey(c))
          .take((count - _rails.length).clamp(0, count))
          .toList();
      await Future.wait(wanted.map(_loadRail));
    } finally {
      _railsLoading = false;
      notifyListeners();
    }
  }

  /// Adds the next unloaded category to the home feed (infinite rails).
  Future<void> loadMoreRails() async {
    if (_railsLoading) return;
    final next = LocalExtractionService.categories
        .where((c) => !_rails.containsKey(c))
        .toList();
    if (next.isEmpty) return;
    _railsLoading = true;
    notifyListeners();
    try {
      await _loadRail(next.first);
    } finally {
      _railsLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadRail(String label) async {
    List<ExploreVideo> items = const [];
    final page = await _serverSearch(label, limit: 8, page: 1, order: 'relevance');
    if (page != null && page.results.isNotEmpty) {
      items = page.results;
    }
    if (items.isEmpty) {
      try {
        items = await _extraction.searchCategory(label, limit: 8);
      } catch (e) {
        debugPrint('[Explore] rail "$label" failed: $e');
      }
    }
    if (items.isEmpty) return;
    // A rail only shows videos that are NOT already on screen elsewhere
    // (continue-watching, for-you, trending, other rails). If nothing fresh
    // is left the rail stays empty instead of repeating items.
    final excluded = _homeIds(
      continueWatching: true,
      trending: true,
      forYou: true,
      rails: true,
    );
    _rails[label] =
        _dedupe(items.where((v) => !excluded.contains(_keyOf(v)))).take(8).toList();
    notifyListeners();
    _saveFeedCache();
  }

  /// Appends the next page of the current search (infinite scroll).
  Future<void> loadMoreResults() async {
    if (_loadingMore || _query.isEmpty || _searchExhausted) return;
    final seq = _searchSeq;
    _loadingMore = true;
    notifyListeners();
    try {
      if (_serverSearchFailed) {
        final more = await _extraction.searchMore(_query, limit: 10);
        if (seq != _searchSeq) return;
        if (more.isEmpty) {
          _searchExhausted = true;
        } else {
          _appendUnique(_videos, more);
        }
      } else {
        final page = await _serverSearch(_query, page: _searchPage + 1);
        if (seq != _searchSeq) return;
        if (page == null) {
          _serverSearchFailed = true;
          _searchExhausted = true;
        } else {
          _searchPage++;
          _searchExhausted = !page.hasMore;
          if (page.results.isNotEmpty) _appendUnique(_videos, page.results);
          if (_videos.isEmpty) _searchExhausted = true;
        }
      }
    } catch (_) {
    } finally {
      if (seq == _searchSeq) {
        _loadingMore = false;
        notifyListeners();
      }
    }
  }

  /// Appends the next page of the current category.
  Future<void> loadMoreCategory() async {
    final cat = _selectedCategory;
    if (_loadingMore || cat == null || _categoryExhausted) return;
    final seq = _searchSeq;
    _loadingMore = true;
    notifyListeners();
    try {
      if (_serverSearchFailed) {
        final more = await _extraction.searchMore('$cat popular', limit: 8);
        if (seq != _searchSeq) return;
        if (more.isEmpty) {
          _categoryExhausted = true;
        } else {
          _appendUnique(_categoryResults, more);
        }
      } else {
        final page = await _serverSearch(cat, page: _categoryPage + 1);
        if (seq != _searchSeq) return;
        if (page == null) {
          _categoryExhausted = true;
        } else {
          _categoryPage++;
          _categoryExhausted = !page.hasMore;
          if (page.results.isNotEmpty) {
            _appendUnique(_categoryResults, page.results);
          }
          if (_categoryResults.isEmpty) _categoryExhausted = true;
        }
      }
    } catch (_) {
    } finally {
      if (seq == _searchSeq) {
        _loadingMore = false;
        notifyListeners();
      }
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
      final excluded = _homeIds(
        continueWatching: true,
        trending: true,
        rails: true,
      );
      final fresh = <ExploreVideo>[];
      final seen = <String>{};
      void absorb(List<ExploreVideo> batch) {
        for (final v in batch) {
          if (v.id.isNotEmpty && seen.add(v.id)) fresh.add(v);
        }
      }

      Future<void> searchAny(String q, {int limit = 6}) async {
        final page = await _serverSearch(q, limit: limit, page: 1);
        if (page != null && page.results.isNotEmpty) {
          absorb(page.results);
          return;
        }
        try {
          absorb(await _extraction.search(q, limit: limit));
        } catch (_) {}
      }

      for (final kw in interests.take(3)) {
        if (fresh.length >= 10) break;
        await searchAny('$kw music');
      }
      final rotating =
          List<String>.from(LocalExtractionService.trendingQueries)..shuffle();
      for (final q in rotating.take(2)) {
        if (fresh.length >= 14) break;
        await searchAny(q);
      }
      try {
        final cats = List<String>.from(LocalExtractionService.categories)
          ..shuffle();
        if (fresh.length < 16 && cats.isNotEmpty) {
          absorb(await _extraction.searchCategory(cats.first, limit: 4));
        }
      } catch (_) {}
      _forYou = _dedupe(_preferUnseen(fresh)
              .where((v) => !excluded.contains(_keyOf(v))))
          .take(12)
          .toList();
      _rememberShown(_forYou);
    } finally {
      _forYouLoading = false;
      notifyListeners();
      _saveFeedCache();
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
    _categoryPage = 1;
    _searchSeq++;
    notifyListeners();

    try {
      if (!ConnectivityService.instance.hasInternet) {
        _categoryLoading = false;
        notifyListeners();
        return;
      }
      final page = await _serverSearch(category, limit: 12, page: 1);
      if (page != null && page.results.isNotEmpty) {
        _categoryResults = _dedupe(page.results);
        _categoryExhausted = !page.hasMore;
      } else {
        _categoryResults =
            _dedupe(await _extraction.searchCategory(category, limit: 8));
        _categoryExhausted = true;
      }
    } catch (_) {
      _categoryResults = [];
    } finally {
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

  /// Real search with pagination. The backend (innertube) answers first; the
  /// on-device youtube_explode search takes over when it cannot.
  Future<void> search(String query) async {
    if (query.trim().isEmpty) return;
    _query = query.trim();
    final seq = ++_searchSeq;
    _loading = true;
    _exploreError = ExploreError.none;
    _error = null;
    _activeTab = ExploreTab.trending;
    _searchExhausted = false;
    _searchPage = 1;
    _serverSearchFailed = false;
    notifyListeners();

    try {
      if (!ConnectivityService.instance.hasInternet) {
        _exploreError = ExploreError.noInternet;
        _loading = false;
        notifyListeners();
        return;
      }

      final page = await _serverSearch(_query, page: 1);
      if (seq != _searchSeq) return;

      if (page != null && page.results.isNotEmpty) {
        _videos = _dedupe(page.results);
        _searchExhausted = !page.hasMore;
      } else {
        if (page == null) _serverSearchFailed = true;
        final local = await _extraction.search(_query);
        if (seq != _searchSeq) return;
        _videos = _dedupe(local);
        _searchExhausted = local.length < 10;
      }
      _addRecentSearch(_query);
      if (_videos.isEmpty) {
        _exploreError = ExploreError.noResults;
      }
    } catch (e) {
      if (seq != _searchSeq) return;
      _exploreError = ExploreError.searchFailed;
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      if (seq == _searchSeq) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Re-runs the active search with a new ordering (relevance / views).
  Future<void> setSort(String value) async {
    if (_sort == value || value.isEmpty) return;
    _sort = value;
    notifyListeners();
    if (_query.isNotEmpty) await search(_query);
  }

  /// Re-runs the active search with a date window (hour / today / week).
  Future<void> setWhen(String value) async {
    if (_when == value || value.isEmpty) return;
    _when = value;
    notifyListeners();
    if (_query.isNotEmpty) await search(_query);
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
    _searchSeq++; // drop any in-flight search
    _videos = [];
    _query = '';
    _loading = false;
    _searchExhausted = false;
    _exploreError = ExploreError.none;
    _error = null;
    notifyListeners();
  }

  /// Resolves a pasted / shared link through the provider resolver and keeps
  /// the outcome so the UI can offer play / download / honest fallback.
  Future<PastedLinkResult?> resolveLink(String url) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    _linkLoading = true;
    _linkResult = null;
    _linkError = null;
    notifyListeners();
    try {
      if (!ConnectivityService.instance.hasInternet) {
        throw const NetworkException('no internet');
      }
      _linkResult =
          await MediaProviderResolver.resolveLink(trimmed, api: _api);
    } catch (e) {
      _linkError = e.toString().replaceFirst('Exception: ', '');
      debugPrint('[Explore] link resolve failed: $e');
    } finally {
      _linkLoading = false;
      notifyListeners();
    }
    return _linkResult;
  }

  void clearLink() {
    _linkResult = null;
    _linkError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
