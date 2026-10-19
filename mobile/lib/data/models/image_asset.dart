/// Decisions about a cover image taken from its URL alone: whether it is a
/// real image the user can save, and under which extension to save it.
///
/// Shared by every model that exposes a cover so the download action, the
/// label shown next to it and the file written on disk can never disagree.
abstract final class ImageAsset {
  /// Extensions that unambiguously point at a standalone image file.
  static const Set<String> extensions = {'.jpg', '.jpeg', '.png', '.webp'};

  /// Hosts that serve their thumbnails as real image files rather than
  /// page previews.
  static const Set<String> hosts = {'i.ytimg.com', 'yt3.ggpht.com'};

  /// True when [url] is an image the user can actually save.
  ///
  /// A thumbnail is not automatically a downloadable image: sources also
  /// return page previews, placeholders and values without a host. Offering
  /// "download image" for those saved a file that was not the content's real
  /// artwork, so the decision lives here, in one place, from the URL itself.
  static bool isDownloadable(String? url) {
    final raw = url?.trim();
    if (raw == null || raw.isEmpty) return false;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (hosts.contains(uri.host.toLowerCase())) return true;
    final path = uri.path.toLowerCase();
    return extensions.any(path.endsWith);
  }

  /// File extension to save [url] under: taken from the URL and defaulting
  /// to jpg, so the label matches what actually gets written.
  static String extensionOf(String? url) {
    final path = Uri.tryParse(url ?? '')?.path.toLowerCase() ?? '';
    for (final ext in extensions) {
      if (path.endsWith(ext)) return ext.substring(1);
    }
    return 'jpg';
  }
}
