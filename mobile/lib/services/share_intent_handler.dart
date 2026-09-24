import 'dart:async';
import 'package:flutter/services.dart';

class ShareIntentHandler {
  static const _channel = MethodChannel('com.example.vibegrab/share');

  static final ShareIntentHandler _instance = ShareIntentHandler._();
  factory ShareIntentHandler() => _instance;
  ShareIntentHandler._();

  String? _pendingUrl;
  final _controller = StreamController<String>.broadcast();

  Stream<String> get onUrlReceived => _controller.stream;
  String? get pendingUrl => _pendingUrl;

  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedUrl') {
        final raw = call.arguments as String?;
        if (raw != null) {
          final url = _extractUrl(raw);
          if (url != null) {
            _pendingUrl = url;
            _controller.add(url);
          }
        }
      }
    });

    _checkInitialUrl();
  }

  Future<void> _checkInitialUrl() async {
    try {
      final url = await _channel.invokeMethod<String>('getInitialSharedUrl');
      if (url != null) {
        final extracted = _extractUrl(url);
        if (extracted != null) {
          _pendingUrl = extracted;
          _controller.add(extracted);
        }
      }
    } catch (_) {}
  }

  void consumePendingUrl() {
    _pendingUrl = null;
  }

  static final _urlRegex = RegExp(
    r'https?://[^\s<>\"{}|\\^`\[\]]+',
    caseSensitive: false,
  );

  static String? _extractUrl(String text) {
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return text.trim();
    }
    final match = _urlRegex.firstMatch(text);
    if (match != null) {
      return match.group(0);
    }
    return null;
  }

  void dispose() {
    _controller.close();
  }
}
