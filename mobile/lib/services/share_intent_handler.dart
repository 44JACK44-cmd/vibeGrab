import 'dart:async';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';

class ShareIntentHandler {
  static const _channel = MethodChannel('com.example.vibegrab/share');

  static final ShareIntentHandler _instance = ShareIntentHandler._();
  factory ShareIntentHandler() => _instance;
  ShareIntentHandler._();

  String? _lastProcessedUrl;
  final _urlController = BehaviorSubject<String>.seeded('');

  Stream<String> get onUrlReceived => _urlController.stream;
  String? get pendingUrl => _lastProcessedUrl;
  String? get lastProcessedUrl => _lastProcessedUrl;

  void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedUrl') {
        final raw = call.arguments as String?;
        if (raw != null) {
          final url = _extractUrl(raw);
          if (url != null) {
            _processUrl(url);
          }
        }
      } else if (call.method == 'getInitialSharedUrl') {
        return _lastProcessedUrl ?? '';
      }
    });
    _checkInitialUrl();
  }

  Future<void> _checkInitialUrl() async {
    try {
      final url = await _channel.invokeMethod<String>('getInitialSharedUrl');
      if (url != null && url.isNotEmpty) {
        _processUrl(url);
      }
    } catch (_) {}
  }

  void _processUrl(String url) {
    final sanitized = ShareIntentHandler.sanitizeUrl(url);
    if (sanitized == _lastProcessedUrl) return;
    _lastProcessedUrl = sanitized;
    _urlController.add(sanitized);
  }

  void consumePendingUrl() {
    _lastProcessedUrl = null;
  }

  static String sanitizeUrl(String url) {
    var cleaned = url.trim();
    cleaned = cleaned.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    final hashIdx = cleaned.indexOf('#');
    if (hashIdx != -1) cleaned = cleaned.substring(0, hashIdx);
    return cleaned;
  }

  static final _urlRegex = RegExp(
    r'https?://[^\s<>\"{}|\\^`\[\]]+',
    caseSensitive: false,
  );

  static final _platformHosts = {
    'youtube.com', 'youtu.be', 'm.youtube.com', 'music.youtube.com',
    'tiktok.com', 'www.tiktok.com',
    'instagram.com', 'www.instagram.com',
    'facebook.com', 'www.facebook.com', 'fb.watch',
    'x.com', 'twitter.com', 'www.x.com', 'www.twitter.com',
    'reddit.com', 'www.reddit.com',
    'vimeo.com', 'www.vimeo.com',
    'soundcloud.com', 'www.soundcloud.com',
    'snapchat.com', 'www.snapchat.com',
    'whatsapp.com', 'web.whatsapp.com',
    'telegram.org', 't.me',
    'linkedin.com', 'www.linkedin.com',
    'pinterest.com', 'www.pinterest.com',
    'twitch.tv', 'www.twitch.tv',
  };

  static String? detectPlatform(String url) {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;
      final host = uri.host.replaceAll('www.', '');
      for (final platform in _platformHosts) {
        if (host == platform || host.endsWith('.$platform')) {
          return platform;
        }
      }
    } catch (_) {}
    return null;
  }

  static String? _extractUrl(String text) {
    final sanitized = sanitizeUrl(text);
    if (sanitized.startsWith('http://') || sanitized.startsWith('https://')) {
      return sanitized;
    }
    final match = _urlRegex.firstMatch(sanitized);
    if (match != null) {
      return match.group(0);
    }
    return null;
  }

  void dispose() {
    _urlController.close();
  }
}
