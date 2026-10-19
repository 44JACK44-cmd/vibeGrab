import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// How a video candidate is delivered to the player.
enum MediaSourceKind {
  /// googlevideo URL played straight from the carrier network.
  directVideo,

  /// googlevideo bytes forwarded by our server (no IP lockout, seeking).
  proxyVideo,

  /// Server-side ffmpeg merge of adaptive streams (only path for videos
  /// without a muxed format).
  relayMerge,

  /// Device manifest muxed stream (last resort, often bot-blocked).
  deviceMuxed,
}

/// One playable video candidate, ordered by preference by the resolver.
class MediaSource {
  final MediaSourceKind kind;
  final Uri uri;
  final Duration initTimeout;

  /// Short tag for error reports (video / proxy / unión / directo).
  final String errTag;

  const MediaSource({
    required this.kind,
    required this.uri,
    required this.initTimeout,
    required this.errTag,
  });
}

/// A known quality from the device manifest (real data only).
class MediaQuality {
  final int height;
  const MediaQuality(this.height);

  String get label => '${height}p';
}

/// Result of resolving a video id into playable candidates.
class MediaResolution {
  /// Ranked video candidates (engine tries them in order).
  final List<MediaSource> video;

  /// Server-forwarded audio fallback (full player state).
  final Uri? audioUri;

  /// Device manifest when it was already available at resolve time
  /// (device audio fallback + quality list). Null while the background
  /// fetch is still running or when the source is bot-blocked.
  final StreamManifest? manifest;

  /// Background manifest fetch, null when [manifest] was already final.
  ///
  /// Resolution deliberately does NOT wait for this: the manifest used to
  /// be awaited next to the server payload, which put a second network leg
  /// of up to 25s in front of the first frame of every video.
  final Future<StreamManifest?>? manifestAsync;

  /// Why the server fetch failed (for error reports), null on success.
  final String? fetchError;

  /// Real qualities known from the device manifest (empty = Auto only).
  final List<MediaQuality> qualities;

  const MediaResolution({
    this.video = const [],
    this.audioUri,
    this.manifest,
    this.manifestAsync,
    this.fetchError,
    this.qualities = const [],
  });
}
