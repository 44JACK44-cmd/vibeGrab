import '../data/models/explore_video.dart';
import 'api_service.dart';

/// Outcome of resolving a pasted/shared link.
class PastedLinkResult {
  final String provider;
  final bool playable;
  final bool downloadable;
  final String? reason;
  final ExploreVideo? video;

  const PastedLinkResult({
    required this.provider,
    required this.playable,
    required this.downloadable,
    this.reason,
    this.video,
  });

  bool get hasVideo => video != null && video!.url.isNotEmpty;
}

/// Common contract every content provider must implement.
///
/// All providers resolve to the same [ExploreVideo] model, so the rest of
/// the app (MediaSourceResolver -> MediaEngine -> player) never needs to
/// know which site the content came from.
abstract class MediaProvider {
  String get name;
  bool canHandle(String url);
  Future<PastedLinkResult> resolve(String url, {ApiService? api});
}

/// YouTube: fully playable inside VibeGrab (search, related, streaming).
class YouTubeProvider implements MediaProvider {
  const YouTubeProvider();

  @override
  String get name => 'youtube';

  @override
  bool canHandle(String url) {
    final id = extractVideoId(url);
    if (id != null) return true;
    final host = _hostOf(url);
    return host == 'youtube.com' || host.endsWith('.youtube.com') || host == 'youtu.be';
  }

  @override
  Future<PastedLinkResult> resolve(String url, {ApiService? api}) async {
    final service = api ?? ApiService();
    try {
      final meta = await service.fetchLinkMetadata(url);
      if (meta.video != null) {
        return PastedLinkResult(
          provider: meta.provider,
          playable: meta.playable,
          downloadable: meta.downloadable,
          reason: meta.reason,
          video: meta.video,
        );
      }
    } catch (_) {
      // Backend unavailable / cold start: derive what we can locally.
    }

    final id = extractVideoId(url);
    if (id == null) {
      return const PastedLinkResult(
        provider: 'youtube',
        playable: false,
        downloadable: false,
        reason: 'invalid_link',
      );
    }
    return PastedLinkResult(
      provider: 'youtube',
      playable: true,
      downloadable: true,
      video: ExploreVideo(
        id: id,
        title: '',
        url: 'https://www.youtube.com/watch?v=$id',
        thumbnail: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        provider: 'youtube',
      ),
    );
  }

  /// Extracts an 11-char YouTube id from any known URL shape.
  static String? extractVideoId(String url) {
    final text = url.trim();
    if (text.isEmpty) return null;
    if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(text)) return text;

    final patterns = [
      RegExp(r'(?:v=|/vi/|youtu\.be/|/shorts/|/embed/|/v/)([A-Za-z0-9_-]{11})'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(text);
      if (m != null) return m.group(1);
    }
    try {
      final uri = Uri.tryParse(text);
      if (uri != null) {
        final v = uri.queryParameters['v'];
        if (v != null && v.length == 11) return v;
        if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.length == 11) {
          final seg = uri.pathSegments.last;
          if (RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(seg)) return seg;
        }
      }
    } catch (_) {}
    return null;
  }
}

/// Any other yt-dlp supported site (TikTok, Instagram, ...): metadata and
/// download are available, in-app playback is reported honestly.
class GenericProvider implements MediaProvider {
  final String providerName;
  const GenericProvider(this.providerName);

  @override
  String get name => providerName;

  @override
  bool canHandle(String url) => Uri.tryParse(url)?.hasAbsolutePath == true;

  @override
  Future<PastedLinkResult> resolve(String url, {ApiService? api}) async {
    final service = api ?? ApiService();
    try {
      final meta = await service.fetchLinkMetadata(url);
      if (meta.video != null) {
        return PastedLinkResult(
          provider: meta.provider,
          playable: meta.playable,
          downloadable: meta.downloadable,
          reason: meta.reason ?? (meta.playable ? null : 'provider_not_playable'),
          video: meta.video,
        );
      }
    } catch (e) {
      return PastedLinkResult(
        provider: providerName,
        playable: false,
        downloadable: false,
        reason: 'metadata_failed',
        video: ExploreVideo(
          id: '',
          title: url,
          url: url,
          provider: providerName,
        ),
      );
    }
    return PastedLinkResult(
      provider: providerName,
      playable: false,
      downloadable: false,
      reason: 'provider_not_playable',
    );
  }
}

/// Detects the provider for a link and resolves it to a common model.
class MediaProviderResolver {
  static const YouTubeProvider _youtube = YouTubeProvider();
  static const _knownHosts = <String, String>{
    'tiktok.com': 'tiktok',
    'instagram.com': 'instagram',
    'facebook.com': 'facebook',
    'twitter.com': 'twitter',
    'x.com': 'twitter',
    'vimeo.com': 'vimeo',
    'dailymotion.com': 'dailymotion',
    'soundcloud.com': 'soundcloud',
    'twitch.tv': 'twitch',
    'reddit.com': 'reddit',
    'pinterest.com': 'pinterest',
    'ted.com': 'ted',
    'kwai.com': 'kwai',
    'bilibili.com': 'bilibili',
  };

  static String? _hostOf(String url) {
    try {
      return (Uri.tryParse(url)?.host ?? '')
          .toLowerCase()
          .replaceAll('www.', '')
          .replaceAll('m.', '');
    } catch (_) {
      return null;
    }
  }

  static MediaProvider detect(String url) {
    if (_youtube.canHandle(url)) return _youtube;
    final host = _hostOf(url) ?? '';
    for (final entry in _knownHosts.entries) {
      if (host == entry.key || host.endsWith('.${entry.key}')) {
        return GenericProvider(entry.value);
      }
    }
    return const GenericProvider('unknown');
  }

  static bool looksLikeLink(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    if (YouTubeProvider.extractVideoId(t) != null) return true;
    final uri = Uri.tryParse(t.startsWith('http') ? t : 'https://$t');
    return uri != null && uri.host.contains('.');
  }

  static Future<PastedLinkResult> resolveLink(String url, {ApiService? api}) {
    return detect(url).resolve(url, api: api);
  }
}

String _hostOf(String url) => MediaProviderResolver._hostOf(url) ?? '';
