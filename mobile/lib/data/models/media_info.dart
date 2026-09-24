class MediaInfo {
  final String id;
  final String title;
  final String? thumbnail;
  final int? duration;
  final String? uploader;
  final String source;

  MediaInfo({
    required this.id,
    required this.title,
    this.thumbnail,
    this.duration,
    this.uploader,
    required this.source,
  });

  factory MediaInfo.fromJson(Map<String, dynamic> json) {
    return MediaInfo(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      thumbnail: json['thumbnail'],
      duration: json['duration'],
      uploader: json['uploader'],
      source: json['source'] ?? 'unknown',
    );
  }

  String get durationFormatted {
    if (duration == null) return '';
    final h = duration! ~/ 3600;
    final m = (duration! % 3600) ~/ 60;
    final s = duration! % 60;
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get sourceLabel {
    switch (source) {
      case 'youtube': return 'YouTube';
      case 'tiktok': return 'TikTok';
      case 'instagram': return 'Instagram';
      case 'twitter': return 'X / Twitter';
      case 'facebook': return 'Facebook';
      case 'vimeo': return 'Vimeo';
      case 'dailymotion': return 'Dailymotion';
      case 'soundcloud': return 'SoundCloud';
      default: return source;
    }
  }
}
