import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rxdart/rxdart.dart';
import 'local_extraction_service.dart';

/// Receives links shared from other apps and keeps them in one bounded,
/// de-duplicated queue.
///
/// Android may deliver a single `onSharedUrl` or a batch `onSharedUrls`
/// (ACTION_SEND_MULTIPLE). Both go through the same path here, so a link is
/// never analysed twice and a second share never replaces a download already
/// queued from the first one.
class ShareIntentHandler {
  static const _channel = MethodChannel('com.example.vibegrab/share');
  static const _maxQueue = 20;

  static final ShareIntentHandler _instance = ShareIntentHandler._();
  factory ShareIntentHandler() => _instance;
  ShareIntentHandler._();

  String? _lastProcessedUrl;
  final _overlayController = ValueNotifier<bool>(false);
  final _urlController = BehaviorSubject<String>.seeded('');
  final _urlsController =
      BehaviorSubject<List<String>>.seeded(const <String>[]);
  final Queue<String> _queue = Queue<String>();
  final ValueNotifier<int> queueCount = ValueNotifier<int>(0);

  /// Legacy single-url stream. Kept for widgets that still handle one link.
  Stream<String> get onUrlReceived => _urlController.stream;

  /// All links delivered by one share event (one for ACTION_SEND).
  Stream<List<String>> get onUrlsReceived => _urlsController.stream;

  ValueListenable<bool> get overlayMode => _overlayController;
  ValueListenable<int> get queuedCount => queueCount;

  /// The next link waiting to be shown. Does not remove it: callers that
  /// actually handle it use [consumePendingUrl].
  String? get pendingUrl => _queue.isEmpty ? null : _queue.first;

  List<String> get queuedUrls => List<String>.unmodifiable(_queue);

  String? get lastProcessedUrl => _lastProcessedUrl;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSharedUrls':
          final args = call.arguments;
          if (args is Map) {
            final raw = args['urls'];
            if (raw is List) {
              _enqueue(raw, overlay: args['overlay'] == true);
            } else if (args['url'] != null) {
              _enqueue(<dynamic>[args['url']], overlay: args['overlay'] == true);
            }
          }
          break;
        case 'onSharedUrl':
          final args = call.arguments;
          final raw = args is Map ? args['url'] : args;
          if (raw != null) {
            _enqueue(<dynamic>[raw], overlay: args is Map && args['overlay'] == true);
          }
          break;
        case 'getInitialSharedUrl':
          return _lastProcessedUrl ?? '';
      }
      return null;
    });
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
          'getInitialShareInfo');
      final raw = info?['urls'];
      final overlay = info?['overlay'] == true;
      if (raw is List && raw.isNotEmpty) {
        _enqueue(raw, overlay: overlay);
      } else {
        final single = info?['url'] as String?;
        if (single != null && single.isNotEmpty) {
          _enqueue(<dynamic>[single], overlay: overlay);
        }
      }
    } catch (_) {}
  }

  /// Public entry point used by the platform handler and by tests. Keeps the
  /// de-duplication rules in one place for every Android intent path.
  @visibleForTesting
  void enqueueSharedUrls(Iterable<String> urls, {required bool overlay}) =>
      _enqueue(urls, overlay: overlay);

  /// Sanitises, de-duplicates and queues a batch of shared texts.
  void _enqueue(Iterable<dynamic> texts, {required bool overlay}) {
    final added = <String>[];
    for (final text in texts) {
      final raw = text?.toString() ?? '';
      final url = _extractUrl(raw);
      if (url == null) continue;
      // The same link can arrive twice in one ACTION_SEND_MULTIPLE. Only the
      // current queue is de-duplicated: a deliberate re-share later must be
      // allowed through (the download sheet already detects saved copies).
      if (_queue.contains(url)) continue;
      if (_queue.length >= _maxQueue) {
        _queue.removeFirst();
      }
      _queue.addLast(url);
      added.add(url);
    }
    if (added.isEmpty) return;
    _overlayController.value = overlay;
    _lastProcessedUrl = added.last;
    queueCount.value = _queue.length;
    _urlsController.add(List<String>.unmodifiable(added));
    for (final url in added) {
      _urlController.add(url);
    }
  }

  /// Removes and returns the next link. Returns null when the queue is empty.
  String? consumePendingUrl() {
    if (_queue.isEmpty) {
      _lastProcessedUrl = null;
      return null;
    }
    final url = _queue.removeFirst();
    _lastProcessedUrl = url;
    queueCount.value = _queue.length;
    return url;
  }

  void removeUrl(String url) {
    if (!_queue.remove(url)) return;
    queueCount.value = _queue.length;
    if (_lastProcessedUrl == url) {
      _lastProcessedUrl = _queue.isEmpty ? null : _queue.first;
    }
  }

  void clearQueue() {
    _queue.clear();
    _lastProcessedUrl = null;
    queueCount.value = 0;
  }

  void exitOverlay() {
    clearQueue();
    _overlayController.value = false;
    // Clear the BehaviorSubject's current value too. Keeping the old URL as
    // the latest event is what replayed the previous share when the overlay
    // was opened again.
    if (!_urlController.isClosed) _urlController.add('');
    if (!_urlsController.isClosed) {
      _urlsController.add(const <String>[]);
    }
  }

  static String sanitizeUrl(String url) =>
      LocalExtractionService.sanitizeUrl(url);

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
    'kwai.com', 'www.kwai.com',
    'kuaishou.com', 'www.kuaishou.com',
    'dailymotion.com', 'www.dailymotion.com', 'dai.ly',
    'v.redd.it',
    '9gag.com', 'www.9gag.com',
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
    if (sanitized.isEmpty) return null;
    if (sanitized.startsWith('http://') || sanitized.startsWith('https://')) {
      // sanitizeUrl prefixes a scheme to anything; only a real host counts.
      final uri = Uri.tryParse(sanitized);
      if (uri != null && uri.host.contains('.')) return sanitized;
    }
    return null;
  }

  void dispose() {
    _urlController.close();
    _urlsController.close();
    queueCount.dispose();
    _overlayController.dispose();
  }
}
