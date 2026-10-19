import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/analyze_response.dart';
import '../../../data/models/media_info.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/app_settings.dart';
import '../../../core/utils/format_picker.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/api_service.dart';
import '../../../services/connectivity_service.dart';

enum SharedSheetStatus { idle, analyzing, ready, downloading, completed, error }

class SharedDownloadController extends ChangeNotifier {
  final LocalExtractionService _extraction;
  final ApiService _api;

  SharedDownloadController({LocalExtractionService? extraction, ApiService? api})
      : _extraction = extraction ?? LocalExtractionService(),
        _api = api ?? ApiService();

  SharedSheetStatus _status = SharedSheetStatus.idle;
  SharedSheetStatus get status => _status;

  String? _url;
  String? get url => _url;

  String? _platform;
  String? get platform => _platform;

  AnalyzeResponse? _result;
  AnalyzeResponse? get result => _result;

  /// Title/thumbnail announced before the format list is ready (the device
  /// extraction knows them one round-trip earlier). Shown in place of the
  /// bare spinner; [_applyResult] clears it once the real response lands.
  MediaInfo? _earlyMedia;

  MediaInfo? get media => _earlyMedia ?? _result?.media;

  /// Adopts metadata that arrived while the analysis is still running, as long
  /// as the sheet is still looking at that same URL and no finished response
  /// has landed meanwhile (the real result is authoritative).
  void _showEarlyMetadata(String url, MediaInfo media) {
    if (_url != url || _result != null) return;
    _earlyMedia = media;
    notifyListeners();
  }

  List<FormatOption> _audioFormats = [];
  List<FormatOption> get audioFormats => List.unmodifiable(_audioFormats);

  List<FormatOption> _videoFormats = [];
  List<FormatOption> get videoFormats => List.unmodifiable(_videoFormats);

  FormatOption? _selectedFormat;
  FormatOption? get selectedFormat => _selectedFormat;

  String? _error;
  String? get error => _error;

  bool _isDownloading = false;
  bool get isDownloading => _isDownloading;

  bool get isAnalyzing => _status == SharedSheetStatus.analyzing;
  bool get isReady => _status == SharedSheetStatus.ready;
  bool get hasResult => _result != null;
  bool get isUnsupportedPlatform => _error == 'unsupported_platform';
  bool get isContentUnavailable => _error == 'content_unavailable';
  bool get isNoInternet => _error == 'no_internet';

  /// Analysis results are cached per URL: re-analysing the same link
  /// (retry button, reopening the sheet, sharing the same video twice)
  /// used to re-run the whole device-vs-backend race from scratch every
  /// time.
  static const _analyzeCacheTtl = Duration(minutes: 10);
  final Map<String, _CachedAnalyze> _analyzeCache = {};

  /// Analysis already running for a URL, so a double tap cannot stack two
  /// device+backend races on top of each other.
  final Map<String, Future<AnalyzeResponse>> _analyzeInFlight = {};

  /// Bumped on every new analysis. A slow response for an older URL must
  /// never overwrite the one the user is looking at now.
  int _analyzeSeq = 0;

  List<FormatOption> get allFormats => [..._audioFormats, ..._videoFormats];

  Future<void> analyzeUrl(String url) async {
    final sanitized = LocalExtractionService.sanitizeUrl(url);
    if (sanitized.trim().isEmpty) {
      _error = 'invalid_url';
      _status = SharedSheetStatus.error;
      notifyListeners();
      return;
    }

    if (!ConnectivityService.instance.hasInternet) {
      _error = 'no_internet';
      _status = SharedSheetStatus.error;
      notifyListeners();
      return;
    }

    final seq = ++_analyzeSeq;
    bool stale() => seq != _analyzeSeq;

    final cached = _analyzeCache[sanitized];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _analyzeCacheTtl) {
      await _applyResult(sanitized, cached.result);
      notifyListeners();
      return;
    }

    _url = sanitized;
    _platform = LocalExtractionService.detectPlatform(sanitized);
    _status = SharedSheetStatus.analyzing;
    _error = null;
    _result = null;
    _earlyMedia = null;
    _selectedFormat = null;
    notifyListeners();

    try {
      final response = await _analyzeUncached(sanitized);
      // A newer analysis owns the sheet now: keep its state instead of
      // painting this stale result over it.
      if (stale()) return;
      _analyzeCache[sanitized] = _CachedAnalyze(response, DateTime.now());
      await _applyResult(sanitized, response);
      if (stale()) return;
      _status = SharedSheetStatus.ready;
    } on NetworkException catch (e) {
      if (stale()) return;
      _error = (e.type == 'connection' || e.type == 'timeout')
          ? 'server_unreachable'
          : e.message;
      _status = SharedSheetStatus.error;
    } catch (e) {
      if (stale()) return;
      _error = LocalExtractionService.friendlyError(e);
      _status = SharedSheetStatus.error;
    } finally {
      notifyListeners();
    }
  }

  /// One analysis per URL: concurrent callers share the same future.
  Future<AnalyzeResponse> _analyzeUncached(String sanitized) {
    final running = _analyzeInFlight[sanitized];
    if (running != null) return running;
    final future = () async {
      if (LocalExtractionService.supportsPlatform(sanitized)) {
        return _firstSuccess<AnalyzeResponse>([
          _extraction
              .extractMedia(
                sanitized,
                // Device metadata lands before the format list: show it.
                onMetadata: (media) => _showEarlyMetadata(sanitized, media),
              )
              .timeout(const Duration(seconds: 25)),
          _api.analyze(sanitized),
        ]);
      }
      return _api.analyze(sanitized);
    }();
    _analyzeInFlight[sanitized] = future;
    future.whenComplete(() {
      if (identical(_analyzeInFlight[sanitized], future)) {
        _analyzeInFlight.remove(sanitized);
      }
    });
    return future;
  }

  Future<void> _applyResult(String sanitized, AnalyzeResponse response) async {
    _url = sanitized;
    // The finished response is authoritative: the early title/thumbnail was
    // only there to fill the wait.
    _earlyMedia = null;
    _result = response;
    if (response.media.source.isNotEmpty) {
      _platform = response.media.source;
    }
    _audioFormats = response.formats.where((f) => f.type == 'audio').toList();
    _videoFormats = response.formats.where((f) => f.type == 'video').toList();
    await _selectDefaultFormat();
    _error = null;
  }

  Future<T> _firstSuccess<T>(List<Future<T>> futures) {
    final completer = Completer<T>();
    var remaining = futures.length;
    Object? firstError;
    StackTrace? firstStack;
    for (final future in futures) {
      future.then((value) {
        if (!completer.isCompleted) completer.complete(value);
      }, onError: (Object e, StackTrace st) {
        firstError ??= e;
        firstStack ??= st;
        remaining--;
        if (remaining == 0 && !completer.isCompleted) {
          completer.completeError(firstError!, firstStack);
        }
      });
    }
    return completer.future;
  }

  /// Abandons the analysis in flight: its result is discarded instead of
  /// landing on a sheet the user already dismissed or pointed elsewhere.
  void cancelAnalysis() {
    _analyzeSeq++;
    _status = SharedSheetStatus.idle;
    _error = null;
    _result = null;
    _earlyMedia = null;
    notifyListeners();
  }

  void selectFormat(FormatOption format) {
    if (_selectedFormat?.id == format.id) return;
    _selectedFormat = format;
    notifyListeners();
  }

  Future<void> _selectDefaultFormat() async {
    String quality = '720p';
    try {
      final prefs = await SharedPreferences.getInstance();
      quality = prefs.getString(AppSettingKeys.defaultQuality) ?? '720p';
    } catch (_) {}
    _selectedFormat = FormatPicker.pick(
      video: _videoFormats,
      audio: _audioFormats,
      quality: quality,
    );
  }

  void reset() {
    _status = SharedSheetStatus.idle;
    _url = null;
    _platform = null;
    _result = null;
    _audioFormats = [];
    _videoFormats = [];
    _selectedFormat = null;
    _error = null;
    _isDownloading = false;
    notifyListeners();
  }

  void setDownloading() {
    _isDownloading = true;
    notifyListeners();
  }

  void setError(String message) {
    _isDownloading = false;
    _error = message;
    _status = SharedSheetStatus.error;
    notifyListeners();
  }

  void setCompleted() {
    _isDownloading = false;
    _status = SharedSheetStatus.completed;
    notifyListeners();
  }

  void dismiss() {
    reset();
  }
}

class _CachedAnalyze {
  final AnalyzeResponse result;
  final DateTime at;
  const _CachedAnalyze(this.result, this.at);
}
