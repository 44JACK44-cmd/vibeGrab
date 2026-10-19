import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import 'media_source.dart';

/// Server stream-URL payload fetcher (injected for tests).
typedef FetchUrls = Future<StreamUrlsPayload?> Function(String videoId);

/// Device manifest fetcher (injected for tests).
typedef FetchManifest = Future<StreamManifest?> Function(String videoId);

/// Server payload: mirrors StreamUrls (video/audio/proxy paths).
class StreamUrlsPayload {
  final String? video;
  final String? audio;
  final String? proxy;
  const StreamUrlsPayload({this.video, this.audio, this.proxy});
}

/// Resolves a YouTube video id into ranked, playable [MediaSource]s:
///
/// ```text
/// Content ID / URL
///       ↓
/// MediaSourceResolver
///       ↓
/// MediaSource (video URL · audio URL · duration · expiration · quality)
///       ↓
/// MediaEngine → just_audio / video_player
/// ```
///
/// Only compatible sources are used: server-resolved URLs (yt-dlp whose
/// signature work happens server-side), the server proxy/relay, and the
/// device manifest. No DRM evasion, no private-signature cracking, no
/// iframes. Temporary URLs are honored through their exact `expire`
/// parameter, never stored past validity.
class MediaSourceResolver {
  final FetchUrls fetchUrls;
  final FetchManifest fetchManifest;

  /// videoId -> server payload + fetch time.
  final Map<String, _CachedPayload> _urlCache = {};

  /// videoId -> device manifest (qualities + audio fallback).
  final Map<String, StreamManifest> _manifestCache = {};

  /// videoId -> manifest fetch already in flight (concurrent resolves for
  /// the same video share one request instead of stacking up).
  final Map<String, Future<StreamManifest?>> _manifestPending = {};

  /// videoId -> server payload fetch already in flight (a prefetch and the
  /// resolve that consumes it must not hit the server twice).
  final Map<String, Future<StreamUrlsPayload?>> _payloadPending = {};

  static const _urlCacheTtl = Duration(hours: 4);

  /// Safety margin before the exact URL expiry.
  static const _expiryMargin = Duration(minutes: 5);

  MediaSourceResolver({
    required this.fetchUrls,
    required this.fetchManifest,
  });

  /// Exact expiry instant parsed from the googlevideo `expire` parameter
  /// (seconds since epoch), null when absent/unparseable.
  static DateTime? expiryOf(String url) {
    try {
      final v = Uri.tryParse(url)?.queryParameters['expire'];
      if (v == null) return null;
      final secs = int.tryParse(v);
      if (secs == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(secs * 1000);
    } catch (_) {
      return null;
    }
  }

  static bool isExpired(String url, {DateTime? now}) {
    final exp = expiryOf(url);
    if (exp == null) return false;
    return (now ?? DateTime.now())
        .isAfter(exp.subtract(_expiryMargin));
  }

  /// Human quality label for a stream height.
  static String qualityLabel(int height) => '${height}p';

  Future<MediaResolution> resolve(
    String videoId, {
    required void Function(String stageKey) onStage,
  }) async {
    // The server payload is the ONLY thing playback needs. The device
    // manifest (qualities, the device-muxed candidate and the audio
    // fallback) used to be awaited right here too: a second network leg of
    // up to 25s in front of the first frame of every single video. It is
    // now requested in the background and only read from cache, so a cold
    // resolve plays the server candidates immediately and the quality list
    // / audio fallback pick the manifest up as soon as it lands.
    onStage('playStageServer');
    onStage('playStageDirect');
    final cachedManifest = _manifestCache[videoId];
    final manifestAsync = _manifestFor(videoId);
    final payload = await _payloadFor(videoId);
    final fetchError = payload == null ? 'sin url' : null;

    final candidates = <MediaSource>[];
    Uri? audioUri;
    if (payload != null) {
      if (payload.video != null && !isExpired(payload.video!)) {
        final uri = Uri.parse(payload.video!);
        candidates.add(MediaSource(
          kind: MediaSourceKind.directVideo,
          uri: uri,
          initTimeout: const Duration(seconds: 5),
          errTag: 'video',
        ));
        candidates.add(MediaSource(
          kind: MediaSourceKind.proxyVideo,
          uri: _proxyUri(payload.video!),
          initTimeout: const Duration(seconds: 18),
          errTag: 'proxy',
        ));
      }
      if (payload.audio != null && !isExpired(payload.audio!)) {
        audioUri = _proxyUri(payload.audio!);
      }
    }

    // Relay merge: independent from the URL fetch (it resolves its own
    // sources server-side). The only path for adaptive-only videos.
    candidates.add(MediaSource(
      kind: MediaSourceKind.relayMerge,
      uri: Uri.parse('${ApiConfig.baseUrl}/api/explore/relay?v=$videoId'),
      initTimeout: const Duration(seconds: 25),
      errTag: 'unión',
    ));

    List<MediaQuality> qualities = const [];
    if (cachedManifest != null) {
      final heights = cachedManifest.muxed
          .map((s) => s.videoResolution.height)
          .where((h) => h > 0)
          .toSet()
          .toList()
        ..sort();
      qualities = heights.map((h) => MediaQuality(h)).toList();
      final best = _bestMuxed(cachedManifest);
      if (best != null) {
        candidates.add(MediaSource(
          kind: MediaSourceKind.deviceMuxed,
          uri: best.url,
          initTimeout: const Duration(seconds: 12),
          errTag: 'directo',
        ));
      }
    }

    return MediaResolution(
      video: candidates,
      audioUri: audioUri,
      manifest: cachedManifest,
      manifestAsync: manifestAsync,
      fetchError: fetchError,
      qualities: qualities,
    );
  }

  Future<StreamUrlsPayload?> _payloadFor(String videoId) async {
    final hit = _urlCache[videoId];
    if (hit != null &&
        DateTime.now().difference(hit.at) < _urlCacheTtl &&
        (hit.payload.video == null || !isExpired(hit.payload.video!))) {
      return hit.payload;
    }
    // A prefetch (started while the previous player is still being torn down)
    // and the resolve that follows it are the same request: share it instead
    // of asking the server twice for the same video.
    final pending = _payloadPending[videoId];
    if (pending != null) return pending;
    final future = () async {
      StreamUrlsPayload? payload;
      try {
        payload = await fetchUrls(videoId);
      } catch (e) {
        debugPrint('[Resolver] fetchUrls failed: $e');
        payload = null;
      }
      if (payload != null) {
        _urlCache[videoId] = _CachedPayload(payload, DateTime.now());
      }
      return payload;
    }();
    _payloadPending[videoId] = future;
    try {
      return await future;
    } finally {
      _payloadPending.remove(videoId);
    }
  }

  /// Fetches the device manifest, sharing a single in-flight request
  /// between concurrent resolves of the same video. Always completes (the
  /// error path returns null) so callers can await it as a last resort.
  Future<StreamManifest?> _manifestFor(String videoId) {
    final hit = _manifestCache[videoId];
    if (hit != null) return Future.value(hit);
    final pending = _manifestPending[videoId];
    if (pending != null) return pending;
    final future = () async {
      try {
        final manifest = await fetchManifest(videoId);
        if (manifest != null) _manifestCache[videoId] = manifest;
        return manifest;
      } catch (e) {
        debugPrint('[Resolver] manifest failed: $e');
        return null;
      } finally {
        _manifestPending.remove(videoId);
      }
    }();
    _manifestPending[videoId] = future;
    return future;
  }

  /// Muxed URL for an exact height (quality switch), closest-lower fallback.
  /// Null when the cached manifest lacks it.
  Uri? muxedUrlFor(String videoId, int height) {
    final manifest = _manifestCache[videoId];
    if (manifest == null) return null;
    final muxed = manifest.muxed.toList();
    if (muxed.isEmpty) return null;
    muxed.sort((a, b) =>
        a.videoResolution.height.compareTo(b.videoResolution.height));
    Uri? best;
    for (final s in muxed) {
      if (s.videoResolution.height <= height) best = s.url;
    }
    return best;
  }

  List<MediaQuality> qualitiesFor(String videoId) {
    final manifest = _manifestCache[videoId];
    if (manifest == null) return const [];
    final heights = manifest.muxed
        .map((s) => s.videoResolution.height)
        .where((h) => h > 0)
        .toSet()
        .toList()
      ..sort();
    return heights.map((h) => MediaQuality(h)).toList();
  }

  void drop(String videoId) {
    _urlCache.remove(videoId);
    _manifestCache.remove(videoId);
  }

  static Uri _proxyUri(String target) =>
      Uri.parse('${ApiConfig.baseUrl}/api/explore/proxy')
          .replace(queryParameters: {'u': target});

  static MuxedStreamInfo? _bestMuxed(StreamManifest manifest) {
    final muxed = manifest.muxed.toList();
    if (muxed.isEmpty) return null;
    muxed.sort((a, b) {
      final heightDiff =
          b.videoResolution.height.compareTo(a.videoResolution.height);
      if (heightDiff != 0) return heightDiff;
      return b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
    });
    final upTo480 =
        muxed.where((s) => s.videoResolution.height <= 480).toList();
    if (upTo480.isNotEmpty) return upTo480.first;
    final upTo720 =
        muxed.where((s) => s.videoResolution.height <= 720).toList();
    if (upTo720.isNotEmpty) return upTo720.first;
    return muxed.last;
  }
}

class _CachedPayload {
  final StreamUrlsPayload payload;
  final DateTime at;
  const _CachedPayload(this.payload, this.at);
}
