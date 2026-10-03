class RelatedVideo {
  final String id;
  final String title;
  final String thumbnail;
  final String? channel;
  final String? views;
  final String? viewsLabel;
  final String? age;
  final String? duration;

  const RelatedVideo({
    required this.id,
    required this.title,
    required this.thumbnail,
    this.channel,
    this.views,
    this.viewsLabel,
    this.age,
    this.duration,
  });

  factory RelatedVideo.fromJson(Map<String, dynamic> json) {
    return RelatedVideo(
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      thumbnail: json['thumbnail'] ?? '',
      channel: json['channel'],
      views: json['views'],
      viewsLabel: json['views_label'],
      age: json['age'],
      duration: json['duration'],
    );
  }

  String get displayViews => viewsLabel ?? views ?? '';
}
