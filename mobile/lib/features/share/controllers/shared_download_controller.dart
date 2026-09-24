import 'dart:async';
import 'package:flutter/material.dart';
import '../../../data/models/analyze_response.dart';
import '../../../data/models/media_info.dart';
import '../../../data/models/format_option.dart';
import '../../../services/local_extraction_service.dart';
import '../../../services/connectivity_service.dart';

enum SharedSheetStatus { idle, analyzing, ready, downloading, completed, error }

class SharedDownloadController extends ChangeNotifier {
  final LocalExtractionService _extraction;

  SharedDownloadController({LocalExtractionService? extraction})
      : _extraction = extraction ?? LocalExtractionService();

  SharedSheetStatus _status = SharedSheetStatus.idle;
  SharedSheetStatus get status => _status;

  String? _url;
  String? get url => _url;

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

  Completer<void>? _cancelCompleter;

  List<FormatOption> get allFormats => [..._audioFormats, ..._videoFormats];

  Future<void> analyzeUrl(String url) async {
    if (url.trim().isEmpty) {
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

    _url = url.trim();
    _status = SharedSheetStatus.analyzing;
    _error = null;
    _result = null;
    _selectedFormat = null;
    _cancelCompleter = Completer<void>();
    notifyListeners();

    try {
      _result = await _extraction.extractMedia(url);
      _audioFormats = _result!.formats.where((f) => f.type == 'audio').toList();
      _videoFormats = _result!.formats.where((f) => f.type == 'video').toList();
      _selectDefaultFormat();
      _status = SharedSheetStatus.ready;
    } catch (e) {
      final msg = _friendlyError(e);
      _error = msg;
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

  void _selectDefaultFormat() {
    if (_videoFormats.isNotEmpty) {
      final preferred = _videoFormats.firstWhere(
        (f) => f.quality == '720p',
        orElse: () => _videoFormats.first,
      );
      _selectedFormat = preferred;
    } else if (_audioFormats.isNotEmpty) {
      _selectedFormat = _audioFormats.first;
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString().replaceFirst('Exception: ', '');
    if (msg.contains('TimeoutException') || msg.contains('timeout')) {
      return 'timeout';
    }
    if (msg.contains('SocketException') || msg.contains('Connection refused')) {
      return 'server_unavailable';
    }
    if (msg.contains('Invalid YouTube URL')) {
      return 'invalid_url';
    }
    return msg.isNotEmpty ? msg : 'analysis_failed';
  }

  void reset() {
    _status = SharedSheetStatus.idle;
    _url = null;
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
