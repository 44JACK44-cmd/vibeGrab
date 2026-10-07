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
    // Server payload AND device manifest concurrently: on slow networks
    // each leg can take 10-25s, and running them back-to-back doubles the
    // wait. Attempts stay sequential (ranked), resolution goes parallel.
    onStage('playStageServer');
    onStage('playStageDirect');
    final payloadFuture = _payloadFor(videoId);
    final manifestFuture = _manifestFor(videoId);
    final results = await Future.wait([payloadFuture, manifestFuture]);
    final payload = results[0] as StreamUrlsPayload?;
    final manifest = results[1] as StreamManifest?;
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
    if (manifest != null) {
      final heights = manifest.muxed
          .map((s) => s.videoResolution.height)
          .where((h) => h > 0)
          .toSet()
          .toList()
        ..sort();
      qualities = heights.map((h) => MediaQuality(h)).toList();
      final best = _bestMuxed(manifest);
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
      manifest: manifest,
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
  }

  Future<StreamManifest?> _manifestFor(String videoId) async {
    final hit = _manifestCache[videoId];
    if (hit != null) return hit;
    try {
      final manifest = await fetchManifest(videoId);
      if (manifest != null) _manifestCache[videoId] = manifest;
      return manifest;
    } catch (e) {
      debugPrint('[Resolver] manifest failed: $e');
      return null;
    }
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
