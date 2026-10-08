import 'dart:async';
import 'dart:convert';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../core/constants/api_constants.dart';
import '../data/models/analyze_response.dart';
import '../data/models/format_option.dart';
import '../data/models/media_info.dart';
import '../data/models/explore_video.dart';

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

  static const _supportedPlatforms = ['youtube.com', 'youtu.be'];

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
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return false;
      final host = uri.host.replaceAll('www.', '').replaceAll('m.', '');
      return _supportedPlatforms.any((p) => host == p || host.endsWith('.$p'));
    } catch (_) {
      return false;
    }
  }

  static String? detectPlatform(String url) {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;
      final host = uri.host.replaceAll('www.', '').replaceAll('m.', '');
      if (_supportedPlatforms.any((p) => host == p || host.endsWith('.$p'))) {
        return 'youtube';
      }
    } catch (_) {}
    return null;
  }

  static String friendlyError(Object e) {
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

  Future<AnalyzeResponse> extractMedia(String url) async {
    final platform = detectPlatform(url);
    if (platform == null) {
      throw UnsupportedPlatformException('unknown');
    }
    if (!supportsPlatform(url)) {
      throw UnsupportedPlatformException(platform);
    }

    final videoId = _parseVideoId(url);
    if (videoId == null) {
      throw Exception('Invalid YouTube URL');
    }

    try {
      final video = await _ytc.videos.get(videoId);
      final manifest = await _ytc.videos.streamsClient.getManifest(videoId);

      final media = MediaInfo(
        id: video.id.value,
        title: video.title,
        thumbnail: video.thumbnails.maxResUrl,
        duration: video.duration?.inSeconds,
        uploader: video.author,
        source: 'youtube',
        platform: 'youtube',
      );

      final formats = _buildFormats(manifest);

      return AnalyzeResponse(
        success: true,
        media: media,
        formats: formats,
      );
    } on Exception {
      throw ContentUnavailableException('youtube');
    } catch (e) {
      rethrow;
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

    return formats;
  }

  static String sanitizeUrl(String url) {
    var cleaned = url.trim();
    cleaned = cleaned.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    final hashIdx = cleaned.indexOf('#');
    if (hashIdx != -1) cleaned = cleaned.substring(0, hashIdx);
    return cleaned;
  }

  String? _parseVideoId(String url) {
    final sanitized = sanitizeUrl(url);

    final idMatch = RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})').firstMatch(sanitized);
    if (idMatch != null) return idMatch.group(1);

    final uri = Uri.tryParse(sanitized);
    if (uri == null) return null;

    if (uri.host.contains('youtube.com') || uri.host.contains('youtu.be')) {
      if (uri.host.contains('youtu.be')) {
        final id = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : null;
        if (id != null && id.length == 11) return id;
      }

      final vParam = uri.queryParameters['v'];
      if (vParam != null && vParam.length == 11) return vParam;

      if (uri.pathSegments.length >= 2 && uri.pathSegments[uri.pathSegments.length - 2] == 'shorts') {
        final id = uri.pathSegments.last;
        if (id.length == 11) return id;
      }
    }

    if (sanitized.length == 11 && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sanitized)) {
      return sanitized;
    }

    return null;
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
