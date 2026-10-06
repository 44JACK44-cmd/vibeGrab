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
      if (LocalExtractionService.supportsPlatform(url)) {
        _result = await _extraction.extractMedia(url);
      } else {
        _result = await _api.analyze(url);
      }
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
}
