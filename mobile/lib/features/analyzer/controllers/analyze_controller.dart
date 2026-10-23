import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/media_info.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/analyze_response.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/analysis_failure.dart';
import '../../../services/api_service.dart';
import '../../../services/connectivity_service.dart';

class _CachedAnalysis {
  final AnalyzeResponse response;
  final DateTime storedAt;
  const _CachedAnalysis(this.response, this.storedAt);
}

class AnalyzeController extends ChangeNotifier {
  final LocalExtractionService _extraction;
  final ApiService _api;
  final Duration _cacheTtl;
  final DateTime Function() _clock;

  AnalyzeController({
    LocalExtractionService? extraction,
    ApiService? api,
    Duration cacheTtl = const Duration(minutes: 10),
    DateTime Function()? clock,
  })  : _extraction = extraction ?? LocalExtractionService(),
        _api = api ?? ApiService(),
        _cacheTtl = cacheTtl,
        _clock = clock ?? DateTime.now;

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  /// Generation of the latest [analyze] call: a response that no longer
  /// belongs to it is dropped instead of overwriting the newer result.
  int _analyzeSeq = 0;

  String? _error;
  String? get error => _error;

  AnalyzeResponse? _result;
  AnalyzeResponse? get result => _result;

  /// URL that produced [_result]. Re-analysing the same URL keeps the old
  /// result visible while loading, and a failed refresh must not erase it.
  /// It is also the URL the download buttons must use: the text field can be
  /// edited after the analysis, and downloading whatever is in it would fetch
  /// a different video than the formats shown.
  String? _resultKey;
  String? get analyzedUrl => _resultKey;

  /// Repeated taps (and the format sheet reopening) must not start another
  /// device+backend race for a URL that is already being analysed.
  final Map<String, Future<AnalyzeResponse>> _inFlight = {};
  final Map<String, _CachedAnalysis> _cache = {};
  static const _maxCached = 16;

  MediaInfo? get media => _result?.media;
  List<FormatOption> get formats => _result?.formats ?? [];

  List<FormatOption> get audioFormats =>
      formats.where((f) => f.type == 'audio').toList();

  List<FormatOption> get videoFormats =>
      formats.where((f) => f.type == 'video').toList();

  bool get backendConfigured => true;

  Future<void> analyze(String url, {String? emptyUrlMessage}) async {
    final raw = url.trim();
    if (raw.isEmpty) {
      _error = emptyUrlMessage ?? 'enterUrl';
      notifyListeners();
      return;
    }

    final normalized = LocalExtractionService.sanitizeUrl(raw);
    // Validate before touching the network: a malformed link must get a
    // precise answer ("no es un enlace válido") instead of a 40 s round-trip
    // that ends in a server error.
    if (!LocalExtractionService.looksLikeUrl(normalized)) {
      _analyzeSeq++; // abandon any analysis still running for a previous URL
      _isLoading = false;
      _error = 'analysisInvalidUrl';
      _result = null;
      _resultKey = null;
      notifyListeners();
      return;
    }

    if (!ConnectivityService.instance.hasInternet) {
      _error = 'noInternet';
      notifyListeners();
      return;
    }

    final key = _cacheKey(normalized);

    // A recent analysis of the same URL is reused immediately. This is the
    // normal path when the user closes the format sheet and taps Analyze
    // again, or when a saved URL is reopened.
    final cached = _cache[key];
    if (cached != null &&
        _clock().difference(cached.storedAt) < _cacheTtl) {
      _analyzeSeq++;
      _isLoading = false;
      _error = null;
      _result = cached.response;
      _resultKey = key;
      notifyListeners();
      // Local metric: how long the UI had to wait for the answer. The URL is
      // NOT logged (it can be private).
      debugPrint('[Analyze] cache hit in 0ms');
      return;
    }

    final stopwatch = Stopwatch()..start();

    final sameUrl = _resultKey == key;
    _isLoading = true;
    _error = null;
    // Keep the previous result of THIS URL while refreshing; a new URL must
    // not show metadata from a different video.
    if (!sameUrl) _result = null;
    notifyListeners();

    // Generation of this request: the analyzer races the device against the
    // backend, so a slow response from an older tap must never overwrite
    // what a newer one already resolved.
    final seq = ++_analyzeSeq;

    // One device+backend race per URL. A second tap joins the running one
    // instead of doubling network traffic and provider quota.
    var shared = _inFlight[key];
    if (shared == null) {
      // Race device vs backend: whichever answers first wins. The device
      // side is capped so a hanging phone network can't stall analysis; the
      // backend covers the hosts the device cannot extract. Both paths report
      // a typed AnalysisException, so a failure is never mistaken for a
      // server outage.
      final futures = <Future<AnalyzeResponse>>[
        _extraction.extractMedia(normalized).timeout(const Duration(seconds: 25)),
        _api.analyze(normalized),
      ];
      final race = _firstSuccess<AnalyzeResponse>(futures);
      late final Future<AnalyzeResponse> tracked;
      tracked = race.then((response) {
        _store(key, response);
        return response;
      }).whenComplete(() {
        // The cleanup is part of the future every caller awaits, so a tap
        // right after completion starts a fresh request when the TTL allows.
        if (identical(_inFlight[key], tracked)) _inFlight.remove(key);
      });
      _inFlight[key] = tracked;
      shared = tracked;
    }

    try {
      final response = await shared;
      debugPrint('[Analyze] resolved in ${stopwatch.elapsedMilliseconds}ms');
      if (seq != _analyzeSeq) return;
      _result = response;
      _resultKey = key;
    } on AnalysisException catch (e) {
      if (seq != _analyzeSeq) return;
      // The detail is for the log: it never contains URLs or credentials.
      debugPrint('[Analyze] failed: $e');
      _error = e.messageKey;
    } on NetworkException catch (e) {
      if (seq != _analyzeSeq) return;
      _error = (e.type == 'connection' || e.type == 'timeout')
          ? 'serverUnreachable'
          : 'analysisServerError';
    } catch (e) {
      if (seq != _analyzeSeq) return;
      debugPrint('[Analyze] unexpected: ${e.runtimeType}');
      _error = 'analysisFailed';
    } finally {
      // Only the newest request owns the loading flag and the notification.
      if (seq == _analyzeSeq) {
        _isLoading = false;
        notifyListeners();
      }
    }
  }

  static String _cacheKey(String url) => LocalExtractionService.sanitizeUrl(url);

  /// Drops an error banner that no longer describes what the user is doing
  /// (they edited the URL). The result, if any, stays on screen.
  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  void _store(String key, AnalyzeResponse response) {
    if (!response.success) return;
    // Re-insert so the most recently used entry is the last one evicted.
    _cache.remove(key);
    _cache[key] = _CachedAnalysis(response, _clock());
    while (_cache.length > _maxCached) {
      _cache.remove(_cache.keys.first);
    }
  }

  void clear() {
    // Abandons any in-flight analysis: its response can no longer land.
    _analyzeSeq++;
    _result = null;
    _resultKey = null;
    _error = null;
    _isLoading = false;
    notifyListeners();
  }

  /// Completes with the first SUCCESSFUL future; slow losers are ignored.
  /// (Same race the share sheet uses: device vs backend.)
  ///
  /// When every path fails it reports the most informative cause, not the
  /// first one to fail: a device timeout must not hide the backend's
  /// "source refused the request".
  Future<T> _firstSuccess<T>(List<Future<T>> futures) {
    final completer = Completer<T>();
    var remaining = futures.length;
    final errors = <Object>[];
    final stacks = <StackTrace>[];
    for (final future in futures) {
      future.then((value) {
        if (!completer.isCompleted) completer.complete(value);
      }, onError: (Object e, StackTrace st) {
        errors.add(e);
        stacks.add(st);
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          final index = _mostInformativeError(errors);
          completer.completeError(errors[index], stacks[index]);
        }
      });
    }
    return completer.future;
  }

  /// Index of the failure that best explains the problem.
  ///
  /// A typed cause (private, no formats, source blocked, bad response) says
  /// more than "it timed out" or "unknown", so it wins even if it arrived
  /// last.
  static int _mostInformativeError(List<Object> errors) {
    int score(Object error) {
      if (error is! AnalysisException) return 0;
      switch (error.type) {
        case AnalysisFailureType.unavailable:
        case AnalysisFailureType.noFormats:
        case AnalysisFailureType.unsupportedPlatform:
        case AnalysisFailureType.invalidUrl:
        case AnalysisFailureType.malformedResponse:
        case AnalysisFailureType.httpError:
          return 3;
        case AnalysisFailureType.unknown:
          return 2;
        case AnalysisFailureType.timeout:
        case AnalysisFailureType.network:
          return 1;
      }
    }

    var best = 0;
    for (var i = 1; i < errors.length; i++) {
      if (score(errors[i]) > score(errors[best])) best = i;
    }
    return best;
  }
}
