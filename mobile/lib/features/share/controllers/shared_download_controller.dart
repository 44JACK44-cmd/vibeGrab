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

  MediaInfo? get media => _result?.media;

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

  Completer<void>? _cancelCompleter;

  List<FormatOption> get allFormats => [..._audioFormats, ..._videoFormats];

  Future<void> analyzeUrl(String url) async {
    final sanitized = LocalExtractionService.sanitizeUrl(url);
    if (sanitized.trim().isEmpty) {
      _error = 'Invalid URL';
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

    _url = sanitized;
    _platform = LocalExtractionService.detectPlatform(sanitized);
    _status = SharedSheetStatus.analyzing;
    _error = null;
    _result = null;
    _selectedFormat = null;
    _cancelCompleter = Completer<void>();
    notifyListeners();

    try {
      if (LocalExtractionService.supportsPlatform(sanitized)) {
        _result = await _extraction.extractMedia(sanitized);
      } else {
        _result = await _api.analyze(sanitized);
        _platform = _result!.media.source;
      }
      _audioFormats = _result!.formats.where((f) => f.type == 'audio').toList();
      _videoFormats = _result!.formats.where((f) => f.type == 'video').toList();
      await _selectDefaultFormat();
      _status = SharedSheetStatus.ready;
    } on NetworkException catch (e) {
      _error = (e.type == 'connection' || e.type == 'timeout')
          ? 'Server not reachable. Start the VibeGrab server on your PC and check the server URL in Settings.'
          : e.message;
      _status = SharedSheetStatus.error;
    } catch (e) {
      _error = LocalExtractionService.friendlyError(e);
      _status = SharedSheetStatus.error;
    } finally {
      _cancelCompleter?.complete();
      _cancelCompleter = null;
      notifyListeners();
    }
  }

  void cancelAnalysis() {
    if (_cancelCompleter != null && !_cancelCompleter!.isCompleted) {
      _status = SharedSheetStatus.idle;
      _error = null;
      _result = null;
      notifyListeners();
    }
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
    _cancelCompleter = null;
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
