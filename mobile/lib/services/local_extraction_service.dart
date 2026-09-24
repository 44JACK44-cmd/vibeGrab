import 'dart:async';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../data/models/analyze_response.dart';
import '../data/models/format_option.dart';
import '../data/models/media_info.dart';
import '../data/models/explore_video.dart';

class LocalExtractionService {
  final YoutubeExplode _ytc = YoutubeExplode();

  static const trendingQueries = [
    'popular music 2026',
    'trending videos',
    'top music hits',
    'viral videos today',
    'best music videos',
  ];

  static const categories = [
    'Music', 'Gaming', 'News', 'Sports', 'Entertainment',
    'Education', 'Science', 'Comedy', 'Podcasts',
  ];

  void dispose() {
    _ytc.close();
  }

  Future<AnalyzeResponse> extractMedia(String url) async {
    final videoId = _parseVideoId(url);
    if (videoId == null) {
      throw Exception('Invalid YouTube URL');
    }

    final video = await _ytc.videos.get(videoId);
    final manifest = await _ytc.videos.streamsClient.getManifest(videoId);

    final media = MediaInfo(
      id: video.id.value,
      title: video.title,
      thumbnail: video.thumbnails.maxResUrl,
      duration: video.duration?.inSeconds,
      uploader: video.author,
      source: 'youtube',
    );

    final formats = _buildFormats(manifest);

    return AnalyzeResponse(
      success: true,
      media: media,
      formats: formats,
    );
  }

  Future<List<ExploreVideo>> search(String query, {int limit = 10}) async {
    final searchList = await _ytc.search.search(query, filter: TypeFilters.video);
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
