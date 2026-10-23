import 'dart:async';
import 'dart:io' show SocketException;
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import '../data/models/analyze_response.dart';
import '../data/models/format_option.dart';
import '../data/models/media_info.dart';
import '../data/models/explore_video.dart';
import 'analysis_failure.dart';

class ExtractorException implements Exception {
  final String message;
  final String platform;
  final String type;
  ExtractorException(this.message, {this.platform = 'unknown', this.type = 'general'});

  @override
  String toString() => 'ExtractorException: $message (platform=$platform, type=$type)';
}

class UnsupportedPlatformException extends ExtractorException {
  UnsupportedPlatformException(String platform)
      : super('This platform is not supported', platform: platform, type: 'unsupported');
}

class ContentUnavailableException extends ExtractorException {
  ContentUnavailableException(String platform)
      : super('This content is not available', platform: platform, type: 'unavailable');
}

class PlatformNotSupportedException extends ExtractorException {
  PlatformNotSupportedException(String platform)
      : super('This platform is not supported', platform: platform, type: 'unsupported');
}

class LocalExtractionService {
  final YoutubeExplode _ytc = YoutubeExplode();

  static const trendingQueries = [
    'popular music 2026',
    'trending videos',
    'top music hits',
    'viral videos today',
    'best music videos',
  ];

  /// Same rotating seeds in Spanish for es-locale devices (Fase 2B).
  static const trendingQueriesEs = [
    'música popular 2026',
    'videos en tendencia',
    'los éxitos de la semana',
    'videos virales hoy',
    'mejores videoclips',
  ];

  /// Locale-aware rotating seed queries for feed fallbacks.
  static List<String> get feedTrendingQueries =>
      ApiConfig.isSpanishLocale ? trendingQueriesEs : trendingQueries;

  static const categories = [
    'Music', 'Gaming', 'News', 'Sports', 'Entertainment',
    'Education', 'Science', 'Comedy', 'Podcasts',
  ];

  /// Expandable genre groups (music / video / audio / series). Every entry
  /// maps to a real search query; the map is data, not UI, so new genres
  /// only require adding a string here.
  static const Map<String, List<String>> categoryGroups = {
    'Música': [
      'Pop', 'Rock', 'Reggaetón', 'Hip Hop', 'Rap', 'Electrónica', 'Jazz',
      'Clásica', 'Salsa', 'Cumbia', 'Bachata', 'K-Pop', 'Metal', 'Indie',
      'Lo-fi',
    ],
    'Video': [
      'Shorts', 'Entretenimiento', 'Noticias', 'Deportes', 'Tecnología',
      'Gaming', 'Tutoriales', 'Educación', 'Comedia', 'Documentales', 'Vlogs',
    ],
    'Audio': [
      'Podcasts', 'Entrevistas', 'Audiolibros', 'Programas', 'Radio',
    ],
    'Series': [
      'Series', 'Películas', 'Tráilers', 'Animación', 'Clips',
    ],
  };

  /// True for every host that serves the same YouTube videos: `www.`,
  /// `m.`, `music.` and the cookie-less embed domain are equivalent and must
  /// be accepted, not treated as a different platform.
  static bool _isYouTubeHost(String host) {
    final h = host.toLowerCase();
    return h == 'youtube.com' ||
        h.endsWith('.youtube.com') ||
        h == 'youtu.be' ||
        h.endsWith('.youtu.be') ||
        h == 'youtube-nocookie.com' ||
        h.endsWith('.youtube-nocookie.com');
  }

  /// URL-like token inside shared text ("Mira esto https://youtu.be/ID …").
  static final _urlToken = RegExp(
    r'(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}(?::\d{1,5})?(?:[/?#][^\s<>"{}|\\^`\[\]]*)?',
    caseSensitive: false,
  );

  /// Query parameters that never identify the media. Dropping them makes
  /// `youtu.be/ID?si=…`, `watch?v=ID&t=10`, `&feature=share` and the bare ID
  /// share one cache entry (and one analysis) instead of four.
  static const _trackingParams = {
    'si', 'feature', 'pp', 'fbclid', 'gclid', 'igshid', 'igsh',
    'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
    'ref', 'ref_src', 'ref_url', 'spm', 'share_id', 'share_origin',
  };

  /// In-memory search cache (10 min TTL): repeat visits and tab switches
  /// feel instant and don't hammer the network.
  static const _cacheTtl = Duration(minutes: 10);
  final Map<String, _CachedSearch> _searchCache = {};

  /// Last fetched page per query, for real pagination ("load more").
  final Map<String, VideoSearchList> _pages = {};

  void dispose() {
    _ytc.close();
  }

  static bool supportsPlatform(String url) {
    final uri = _parseSanitized(url);
    return uri != null && _isYouTubeHost(uri.host);
  }

  static String? detectPlatform(String url) {
    final uri = _parseSanitized(url);
    if (uri != null && _isYouTubeHost(uri.host)) return 'youtube';
    return null;
  }

  /// Parses user input the same way [sanitizeUrl] normalizes it: accepts
  /// scheme-less links, extracts a URL from shared text and never throws.
  static Uri? _parseSanitized(String url) {
    final cleaned = sanitizeUrl(url);
    if (cleaned.isEmpty) return null;
    final uri = Uri.tryParse(cleaned);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri;
  }

  /// Cheap local validation: reject something that is not a complete URL
  /// before spending a network round-trip on it.
  static bool looksLikeUrl(String url) {
    final uri = _parseSanitized(url);
    if (uri == null) return false;
    final host = uri.host;
    return host.contains('.') && !host.startsWith('.') && !host.endsWith('.');
  }

  static String friendlyError(Object e) {
    if (e is AnalysisException) {
      // Keep the keys the share sheet already renders.
      switch (e.type) {
        case AnalysisFailureType.invalidUrl:
          return 'invalid_url';
        case AnalysisFailureType.unsupportedPlatform:
          return 'unsupported_platform';
        case AnalysisFailureType.network:
          return 'no_internet';
        case AnalysisFailureType.timeout:
          return 'timeout';
        case AnalysisFailureType.unavailable:
          return 'content_unavailable';
        case AnalysisFailureType.httpError:
        case AnalysisFailureType.malformedResponse:
        case AnalysisFailureType.noFormats:
        case AnalysisFailureType.unknown:
          return 'analysis_failed';
      }
    }
    if (e is UnsupportedPlatformException) {
      return 'unsupported_platform';
    }
    if (e is ContentUnavailableException) {
      return 'content_unavailable';
    }
    if (e is PlatformNotSupportedException) {
      return 'unsupported_platform';
    }
    final msg = e.toString();
    if (msg.contains('TimeoutException') || msg.contains('timeout')) {
      return 'timeout';
    }
    if (msg.contains('SocketException') || msg.contains('Connection refused') || msg.contains('Network')) {
      return 'no_internet';
    }
    if (msg.contains('FormatException')) {
      return 'invalid_url';
    }
    if (msg.contains('NoSuchFileError') || msg.contains('FileNotFoundException')) {
      return 'content_unavailable';
    }
    return 'analysis_failed';
  }

  Future<AnalyzeResponse> extractMedia(
    String url, {
    void Function(MediaInfo media)? onMetadata,
  }) async {
    final sanitized = sanitizeUrl(url);
    if (!looksLikeUrl(sanitized)) {
      throw const AnalysisException(AnalysisFailureType.invalidUrl);
    }
    if (!supportsPlatform(sanitized)) {
      final host = Uri.tryParse(sanitized)?.host ?? '';
      throw AnalysisException(
        AnalysisFailureType.unsupportedPlatform,
        code: 'host',
        detail: host,
      );
    }

    final videoId = _parseVideoId(sanitized);
    if (videoId == null) {
      // A valid YouTube URL with no video in it: a playlist, a channel or a
      // removed "clip". It is not an "invalid URL", so say what it is.
      final path = Uri.tryParse(sanitized)?.path ?? '';
      throw AnalysisException(
        AnalysisFailureType.unsupportedPlatform,
        code: path.contains('/clip/') ? 'clip' : 'no_video_id',
        detail: path,
      );
    }

    try {
      final video = await _ytc.videos
          .get(videoId)
          .timeout(const Duration(seconds: 20));

      final media = MediaInfo(
        id: video.id.value,
        title: video.title,
        thumbnail: video.thumbnails.maxResUrl,
        duration: video.duration?.inSeconds,
        uploader: video.author,
        source: 'youtube',
        platform: 'youtube',
      );

      // The manifest (the format list) is a second, slower round-trip. Hand
      // the title and thumbnail over as soon as they are known so the sheet
      // shows what it found instead of a bare spinner for the whole wait.
      onMetadata?.call(media);

      final manifest = await _ytc.videos.streamsClient
          .getManifest(videoId)
          .timeout(const Duration(seconds: 20));

      final formats = _buildFormats(manifest);
      if (formats.isEmpty) {
        throw const AnalysisException(AnalysisFailureType.noFormats);
      }

      return AnalyzeResponse(
        success: true,
        media: media,
        formats: formats,
      );
    } on AnalysisException {
      rethrow;
    } on TimeoutException {
      throw const AnalysisException(AnalysisFailureType.timeout);
    } on SocketException {
      throw const AnalysisException(AnalysisFailureType.network);
    } catch (e) {
      // youtube_explode reports private/removed/region-locked uploads with
      // its own exception types. Keep the cause instead of turning every one
      // of them into the same "content unavailable" (which hid real network
      // and parser failures too).
      final text = e.toString().toLowerCase();
      if (text.contains('unavailable') ||
          text.contains('private') ||
          text.contains('removed') ||
          text.contains('not available') ||
          text.contains('age-restricted') ||
          text.contains('age restricted')) {
        throw AnalysisException(
          AnalysisFailureType.unavailable,
          code: e.runtimeType.toString(),
        );
      }
      throw AnalysisException(
        AnalysisFailureType.unknown,
        detail: e.runtimeType.toString(),
      );
    }
  }

  Future<List<ExploreVideo>> search(String query, {int limit = 10}) async {
    final key = query.trim().toLowerCase();
    final hit = _searchCache[key];
    if (hit != null &&
        DateTime.now().difference(hit.at) < _cacheTtl &&
        hit.videos.length >= limit) {
      return hit.videos.take(limit).toList();
    }
    final searchList = await _ytc.search.search(query, filter: TypeFilters.video);
    _pages[key] = searchList;
    final results = _toVideos(searchList.take(limit));
    final prev = hit?.videos ?? const <ExploreVideo>[];
    final merged = <ExploreVideo>[...results];
    final seen = merged.map((e) => e.id).toSet();
    for (final v in prev) {
      if (merged.length >= limit && hit != null) break;
      if (seen.add(v.id)) merged.add(v);
    }
    _searchCache[key] = _CachedSearch(merged, DateTime.now());
    return results;
  }

  /// Next page of a previous [search] (infinite scroll). Returns [] when
  /// there is nothing more.
  Future<List<ExploreVideo>> searchMore(String query, {int limit = 10}) async {
    final key = query.trim().toLowerCase();
    var page = _pages[key];
    if (page == null) return search(query, limit: limit);
    try {
      final next = await page.nextPage();
      if (next == null || next.isEmpty) return [];
      _pages[key] = next;
      final results = _toVideos(next.take(limit));
      final hit = _searchCache[key];
      if (hit != null) {
        final seen = hit.videos.map((e) => e.id).toSet();
        final grown = <ExploreVideo>[...hit.videos];
        for (final v in results) {
          if (seen.add(v.id)) grown.add(v);
        }
        _searchCache[key] = _CachedSearch(grown, hit.at);
      }
      return results;
    } catch (_) {
      return [];
    }
  }

  /// Short vertical-friendly videos: real search results filtered to short
  /// durations (YouTube Shorts live ≤ 3 min).
  Future<List<ExploreVideo>> searchShorts(String query, {int limit = 12}) async {
    final results = await search(query, limit: limit * 2);
    final shorts = results
        .where((v) => v.duration != null && v.duration! > 0 && v.duration! <= 180)
        .take(limit)
        .toList();
    if (shorts.length >= limit ~/ 2) return shorts;
    // Top up with a second query when the first had few short videos.
    try {
      final more = await search('$query shorts', limit: limit);
      final seen = shorts.map((e) => e.id).toSet();
      for (final v in more) {
        if (shorts.length >= limit) break;
        if (v.duration != null &&
            v.duration! > 0 &&
            v.duration! <= 180 &&
            seen.add(v.id)) {
          shorts.add(v);
        }
      }
    } catch (_) {}
    return shorts;
  }

  List<ExploreVideo> _toVideos(Iterable<Video> videos) {
    return videos
        .map((video) => ExploreVideo(
              id: video.id.value,
              title: video.title,
              url: 'https://www.youtube.com/watch?v=${video.id.value}',
              thumbnail: video.thumbnails.maxResUrl,
              channel: video.author,
              duration: video.duration?.inSeconds,
              viewCount: null,
            ))
        .toList();
  }

  List<FormatOption> _buildFormats(StreamManifest manifest) {
    final formats = <FormatOption>[];
    final seenMuxedHeights = <int>{};
    final seenVideoOnlyHeights = <int>{};
    final seenBitrates = <String>{};

    for (final muxed in manifest.muxed) {
      final height = muxed.videoResolution.height;
      if (!seenMuxedHeights.contains(height)) {
        seenMuxedHeights.add(height);
        formats.add(FormatOption(
          id: muxed.tag.toString(),
          type: 'video',
          extension: muxed.container.name,
          quality: '${height}p',
          hasVideo: true,
          hasAudio: true,
          sizeBytes: muxed.size.totalBytes,
        ));
      }
    }

    for (final videoOnly in manifest.videoOnly) {
      final height = videoOnly.videoResolution.height;
      if (!seenMuxedHeights.contains(height) && !seenVideoOnlyHeights.contains(height)) {
        seenVideoOnlyHeights.add(height);
        formats.add(FormatOption(
          id: videoOnly.tag.toString(),
          type: 'video',
          extension: videoOnly.container.name,
          quality: '${height}p (no audio)',
          hasVideo: true,
          hasAudio: false,
          sizeBytes: videoOnly.size.totalBytes,
        ));
      }
    }

    final sortedAudio = manifest.audioOnly.toList()
      ..sort((a, b) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));

    for (final audio in sortedAudio) {
      final bitrateLabel = '${(audio.bitrate.bitsPerSecond / 1000).round()}kbps';
      if (!seenBitrates.contains(bitrateLabel)) {
        seenBitrates.add(bitrateLabel);
        formats.add(FormatOption(
          id: audio.tag.toString(),
          type: 'audio',
          extension: audio.container.name,
          quality: bitrateLabel,
          hasVideo: false,
          hasAudio: true,
          sizeBytes: audio.size.totalBytes,
        ));
      }
    }

    // Always offer a real MP3 when the media has audio. If there is no
    // audio-only track (some uploads only publish muxed rows) the smallest
    // muxed stream is the source and the backend extracts its audio.
    String? mp3Tag;
    int? mp3Size;
    Uri? mp3Url;
    if (sortedAudio.isNotEmpty) {
      mp3Tag = sortedAudio.first.tag.toString();
      mp3Size = sortedAudio.first.size.totalBytes;
      mp3Url = sortedAudio.first.url;
    } else if (manifest.muxed.isNotEmpty) {
      final smallest = manifest.muxed.toList()
        ..sort((a, b) =>
            a.videoResolution.height.compareTo(b.videoResolution.height));
      mp3Tag = smallest.first.tag.toString();
      mp3Size = smallest.first.size.totalBytes;
      mp3Url = smallest.first.url;
    }
    if (mp3Tag != null) {
      final option = mp3FormatOption(
        tag: mp3Tag,
        sizeBytes: mp3Size,
        url: mp3Url,
      );
      if (option != null) formats.add(option);
    }

    return formats;
  }

  /// Builds the synthetic MP3 menu row. Kept pure so the test can verify the
  /// signed source URL is carried into [FormatOption.directUrl].
  @visibleForTesting
  static FormatOption? mp3FormatOption({
    required String tag,
    int? sizeBytes,
    Uri? url,
  }) {
    if (tag.isEmpty) return null;
    return FormatOption(
      id: '${tag}__mp3',
      type: 'audio',
      extension: 'mp3',
      quality: '192 kbps',
      hasVideo: false,
      hasAudio: true,
      sizeBytes: sizeBytes,
      // The phone's own signed track URL. Without it the MP3 download had
      // to resolve the manifest again (and failed with "no streams" when
      // YouTube blocked that second request); the downloader can now get
      // this source directly and send it to the encoder.
      directUrl: url?.toString(),
    );
  }

  static String sanitizeUrl(String url) {
    var cleaned = url.trim();
    cleaned = cleaned.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return '';

    // A bare 11-character video id is legitimate input (the app itself
    // stores ids in some places): keep it untouched.
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(cleaned)) return cleaned;

    // Shared text ("look at this: https://… wow") → the URL only.
    final token = _urlToken.firstMatch(cleaned);
    if (token != null) cleaned = token.group(0)!;
    // Messaging apps append punctuation after the link.
    cleaned = cleaned.replaceAll(RegExp(r'[)\]}>.,;:!?"\u00BB\u2019]+$'), '');
    if (cleaned.isEmpty) return '';

    // Scheme-less links are common when pasting (`youtu.be/ID`). Without a
    // scheme `Uri.tryParse` reads the host as a path and every check fails.
    // Only add it to something that can be a host: prefixing arbitrary text
    // turned "not a url" into "https://not a url" and made the error opaque.
    if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(cleaned)) {
      final hostLike = RegExp(
        r'^(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d{1,5})?(?:[/?#]|$)',
        caseSensitive: false,
      ).hasMatch(cleaned);
      if (!hostLike) return cleaned;
      cleaned = 'https://$cleaned';
    }

    var uri = Uri.tryParse(cleaned);
    if (uri == null || uri.host.isEmpty) return cleaned;

    // Fragments never reach the server; tracking parameters only make two
    // spellings of the same video look like different media.
    final params = Map<String, String>.from(uri.queryParameters);
    final hadTracking =
        params.keys.any((k) => _trackingParams.contains(k.toLowerCase()));
    if (hadTracking) {
      params.removeWhere(
          (k, _) => _trackingParams.contains(k.toLowerCase()));
    }
    if (hadTracking || uri.hasFragment) {
      // `Uri.replace(fragment: null)` KEEPS the current fragment (null means
      // "unchanged" there), so drop it explicitly.
      if (uri.hasFragment) uri = uri.removeFragment();
      if (hadTracking) {
        uri = uri.replace(
          queryParameters: params.isEmpty ? const {} : params,
        );
      }
    }

    final videoId = _videoIdFromUri(uri);
    if (videoId != null) {
      // One canonical spelling for every equivalent YouTube link: the cache
      // and the download pipeline see the same value for all of them.
      return 'https://www.youtube.com/watch?v=$videoId';
    }
    return uri.toString();
  }

  /// Video id from an already normalized [uri], or null when the URL is not a
  /// single watchable video (channel, playlist, clip…).
  static String? _videoIdFromUri(Uri uri) {
    final host = uri.host.toLowerCase();
    if (!_isYouTubeHost(host)) return null;

    bool valid(String? id) =>
        id != null && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id);

    if (host == 'youtu.be' || host.endsWith('.youtu.be')) {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      return segments.isNotEmpty && valid(segments.first) ? segments.first : null;
    }

    if (valid(uri.queryParameters['v'])) return uri.queryParameters['v'];

    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    const kinds = {'shorts', 'embed', 'v', 'vi', 'live', 'e'};
    if (segments.length >= 2 && kinds.contains(segments[segments.length - 2])) {
      final id = segments.last;
      if (valid(id)) return id;
    }
    // Legacy `youtube.com/VIDEOID` form.
    if (segments.length == 1 && valid(segments.first)) return segments.first;
    return null;
  }

  String? _parseVideoId(String url) {
    final sanitized = sanitizeUrl(url);
    final uri = Uri.tryParse(sanitized);
    if (uri == null || uri.host.isEmpty) {
      return sanitized.length == 11 &&
              RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(sanitized)
          ? sanitized
          : null;
    }
    return _videoIdFromUri(uri);
  }

  Future<List<ExploreVideo>> getTrending({int limit = 12}) async {
    final allResults = <ExploreVideo>[];
    final seenIds = <String>{};

    for (final query in trendingQueries) {
      if (allResults.length >= limit) break;
      try {
        final searchList = await _ytc.search.search(query, filter: TypeFilters.video);
        for (final video in searchList) {
          if (allResults.length >= limit) break;
          if (!seenIds.contains(video.id.value)) {
            seenIds.add(video.id.value);
            allResults.add(ExploreVideo(
              id: video.id.value,
              title: video.title,
              url: 'https://www.youtube.com/watch?v=${video.id.value}',
              thumbnail: video.thumbnails.maxResUrl,
              channel: video.author,
              duration: video.duration?.inSeconds,
              viewCount: null,
            ));
          }
        }
      } catch (_) {}
    }

    return allResults;
  }

  Future<List<ExploreVideo>> searchCategory(String category, {int limit = 8}) async {
    try {
      final searchList = await _ytc.search.search('$category popular', filter: TypeFilters.video);
      final results = <ExploreVideo>[];
      for (final video in searchList.take(limit)) {
        results.add(ExploreVideo(
          id: video.id.value,
          title: video.title,
          url: 'https://www.youtube.com/watch?v=${video.id.value}',
          thumbnail: video.thumbnails.maxResUrl,
          channel: video.author,
          duration: video.duration?.inSeconds,
          viewCount: null,
        ));
      }
      return results;
    } catch (_) {
      return [];
    }
  }
}

/// Cached search result with fetch time (TTL enforced by callers).
class _CachedSearch {
  final List<ExploreVideo> videos;
  final DateTime at;
  const _CachedSearch(this.videos, this.at);
}
