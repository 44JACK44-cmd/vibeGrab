/// A remote (Explorer/YouTube) item the user liked.
/// kind: 'video' or 'audio'. Persisted in MediaMetadataService.
class LikedVideo {
  final String url;
  final String title;
  final String? artist;
  final String? thumbnail;
  final String kind;
  final String savedAt;

  const LikedVideo({
    required this.url,
    required this.title,
    this.artist,
    this.thumbnail,
    this.kind = 'video',
    required this.savedAt,
  });

  bool get isVideo => kind == 'video';

  factory LikedVideo.fromJson(Map<String, dynamic> json) {
    return LikedVideo(
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String?,
      thumbnail: json['thumbnail'] as String?,
      kind: json['kind'] as String? ?? 'video',
      savedAt: json['savedAt'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'artist': artist,
        'thumbnail': thumbnail,
        'kind': kind,
        'savedAt': savedAt,
      };
}
