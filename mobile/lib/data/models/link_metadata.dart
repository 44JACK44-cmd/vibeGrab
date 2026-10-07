import 'explore_video.dart';

/// Metadata resolved from a pasted/shared link (any supported provider).
class LinkMetadata {
  final String provider;
  final bool playable;
  final bool downloadable;
  final String? reason;
  final ExploreVideo? video;

  const LinkMetadata({
    required this.provider,
    required this.playable,
    this.downloadable = true,
    this.reason,
    this.video,
  });

  factory LinkMetadata.fromJson(Map<String, dynamic> json) {
    final videoJson = json['video'];
    return LinkMetadata(
      provider: (json['provider'] ?? 'unknown').toString(),
      playable: json['playable'] == true,
      downloadable: json['downloadable'] != false,
      reason: json['reason']?.toString(),
      video: videoJson is Map<String, dynamic>
          ? ExploreVideo.fromJson(videoJson)
          : null,
    );
  }
}
