import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/media_info.dart';
import '../../../data/models/format_option.dart';
import '../../../data/models/analyze_response.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/api_service.dart';
import '../../../services/connectivity_service.dart';

class AnalyzeController extends ChangeNotifier {
  final LocalExtractionService _extraction;
  final ApiService _api;

  AnalyzeController({LocalExtractionService? extraction, ApiService? api})
      : _extraction = extraction ?? LocalExtractionService(),
        _api = api ?? ApiService();

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? _error;
  String? get error => _error;

  AnalyzeResponse? _result;
  AnalyzeResponse? get result => _result;

  String? _pendingSharedUrl;
  String? get pendingSharedUrl => _pendingSharedUrl;

  MediaInfo? get media => _result?.media;
  List<FormatOption> get formats => _result?.formats ?? [];

  List<FormatOption> get audioFormats =>
      formats.where((f) => f.type == 'audio').toList();

  List<FormatOption> get videoFormats =>
      formats.where((f) => f.type == 'video').toList();

  bool get backendConfigured => true;

  void setPendingSharedUrl(String url) {
    if (_pendingSharedUrl == url || _isLoading) return;
    _pendingSharedUrl = url;
    notifyListeners();
    analyze(url);
  }

  void consumePendingUrl() {
    _pendingSharedUrl = null;
  }

  Future<void> analyze(String url, {String? emptyUrlMessage}) async {
    if (url.trim().isEmpty) {
      _error = emptyUrlMessage ?? 'enterUrl';
      notifyListeners();
      return;
    }

    if (!ConnectivityService.instance.hasInternet) {
      _error = 'noInternet';
      notifyListeners();
      return;
    }

    _isLoading = true;
    _error = null;
    _result = null;
    notifyListeners();

    try {
      // Race device vs backend: whichever answers first wins. The device
      // side is capped so a hanging phone network can't stall analysis.
      _result = await _firstSuccess<AnalyzeResponse>([
        _extraction.extractMedia(url).timeout(const Duration(seconds: 25)),
        _api.analyze(url),
      ]);
    } on NetworkException catch (e) {
      _error = (e.type == 'connection' || e.type == 'timeout')
          ? 'serverUnreachable'
          : e.message;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
    } finally {
      _isLoading = false;
      _pendingSharedUrl = null;
      notifyListeners();
    }
  }

  void clear() {
    _result = null;
    _error = null;
    _isLoading = false;
    _pendingSharedUrl = null;
    notifyListeners();
  }

  /// Completes with the first SUCCESSFUL future; slow losers are ignored.
  /// (Same race the share sheet uses: device vs backend.)
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
}
