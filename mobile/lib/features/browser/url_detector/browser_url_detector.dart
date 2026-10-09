/// Decides whether a browsed URL points at a concrete media page the
/// download pipeline can handle.
///
/// Mirrors the backend `ALLOWED_DOMAINS` list and only matches paths that
/// actually contain a media id (home/search/profile pages never match), so
/// the browser's floating download button appears exactly when a download
/// can succeed.
class BrowserUrlDetector {
  BrowserUrlDetector._();

  /// Returns the URL to analyze when [raw] is a downloadable media page,
  /// `null` otherwise.
  static String? downloadableUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') return null;

    final host =
        uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m|music|mobile)\.'), '');
    final path = uri.path;

    if (host == 'youtu.be') {
      return _hasMediaId(path.substring(1)) ? uri.toString() : null;
    }
    if (host == 'youtube.com' || host.endsWith('.youtube.com')) {
      if (path == '/watch' && (uri.queryParameters['v'] ?? '').isNotEmpty) {
        return uri.toString();
      }
      if (path.startsWith('/shorts/')) {
        return _hasMediaId(path.substring('/shorts/'.length))
            ? uri.toString()
            : null;
      }
      if (path.startsWith('/live/')) {
        return _hasMediaId(path.substring('/live/'.length))
            ? uri.toString()
            : null;
      }
      return null;
    }
    if (host == 'tiktok.com' || host.endsWith('.tiktok.com')) {
      if (RegExp(r'^/@[^/]+/video/\d+').hasMatch(path)) return uri.toString();
      if (path.startsWith('/t/')) return uri.toString();
      if ((host.startsWith('vm.') || host.startsWith('vt.')) && path.length > 1) {
        return uri.toString();
      }
      return null;
    }
    if (host == 'instagram.com' || host.endsWith('.instagram.com')) {
      if (RegExp(r'^/(p|reel|reels|tv)/[A-Za-z0-9_-]+').hasMatch(path)) {
        return uri.toString();
      }
      return null;
    }
    if (host == 'x.com' ||
        host == 'twitter.com' ||
        host.endsWith('.x.com') ||
        host.endsWith('.twitter.com')) {
      if (RegExp(r'^/[^/]+/status/\d+').hasMatch(path)) return uri.toString();
      return null;
    }
    if (host == 'facebook.com' || host.endsWith('.facebook.com')) {
      if (path.startsWith('/watch') ||
          RegExp(r'^/(reel|reels|videos)/').hasMatch(path)) {
        return uri.toString();
      }
      return null;
    }
    if (host == 'vimeo.com' || host.endsWith('.vimeo.com')) {
      final segments = path.split('/')..removeWhere((s) => s.isEmpty);
      if (segments.length == 1 && RegExp(r'^\d+$').hasMatch(segments.first)) {
        return uri.toString();
      }
      return null;
    }
    if (host == 'dailymotion.com' || host.endsWith('.dailymotion.com')) {
      if (path.startsWith('/video/')) return uri.toString();
      return null;
    }
    if (host == 'soundcloud.com' || host.endsWith('.soundcloud.com')) {
      final segments = path.split('/')..removeWhere((s) => s.isEmpty);
      return segments.length >= 2 ? uri.toString() : null;
    }
    return null;
  }

  /// Media ids are alphanumeric (YouTube: 11 chars, others vary); anything
  /// shorter than 5 chars is a residual path, not a real id.
  static bool _hasMediaId(String value) =>
      RegExp(r'^[A-Za-z0-9_-]{5,}$').hasMatch(value);
}
