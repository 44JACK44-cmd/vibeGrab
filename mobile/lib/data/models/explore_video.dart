import '../../core/localization/app_localizations.dart';

class ExploreVideo {
  final String id;
  final String title;
  final String url;
  final String? thumbnail;
  final String? channel;
  final String? channelId;
  final int? duration;
  final String? durationString;
  final int? viewCount;
  final String? viewsLabel;
  final String? age;
  final String provider;
  final int? resumeMs;

  const ExploreVideo({
    required this.id,
    required this.title,
    required this.url,
    this.thumbnail,
    this.channel,
    this.channelId,
    this.duration,
    this.durationString,
    this.viewCount,
    this.viewsLabel,
    this.age,
    this.provider = 'youtube',
    this.resumeMs,
  });

  bool get isYouTube => provider == 'youtube';

  /// Saved playback position of a previously watched video (continue list).
  bool get hasResume => resumeMs != null && resumeMs! > 10000;

  String get resumeLabel {
    final d = Duration(milliseconds: resumeMs ?? 0);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  factory ExploreVideo.fromJson(Map<String, dynamic> json) {
    return ExploreVideo(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      url: json['url'] ?? '',
      thumbnail: json['thumbnail'],
      channel: json['channel'],
      channelId: json['channel_id'],
      duration: json['duration'],
      durationString: json['duration_string'],
      viewCount: json['view_count'],
      viewsLabel: json['views_label'],
      age: json['age'],
      provider: json['provider'] ?? 'youtube',
      resumeMs: json['resume_ms'],
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'url': url,
        'thumbnail': thumbnail,
        'channel': channel,
        'channel_id': channelId,
        'duration': duration,
        'duration_string': durationString,
        'view_count': viewCount,
        'views_label': viewsLabel,
        'age': age,
        'provider': provider,
        if (resumeMs != null) 'resume_ms': resumeMs,
      };

  String get viewCountFormatted {
    if (viewsLabel != null && viewsLabel!.isNotEmpty) return viewsLabel!;
    if (viewCount == null) return '';
    if (viewCount! >= 1000000000) return '${(viewCount! / 1000000000).toStringAsFixed(1)}B views';
    if (viewCount! >= 1000000) return '${(viewCount! / 1000000).toStringAsFixed(1)}M views';
    if (viewCount! >= 1000) return '${(viewCount! / 1000).toStringAsFixed(0)}K views';
    return '$viewCount views';
  }

  String viewCountLocalized(AppLocalizations loc) {
    if (viewsLabel != null && viewsLabel!.isNotEmpty) return viewsLabel!;
    if (viewCount == null) return '';
    if (viewCount! >= 1000000000) {
      return loc.viewsB((viewCount! / 1000000000).toStringAsFixed(1));
    }
    if (viewCount! >= 1000000) {
      return loc.viewsM((viewCount! / 1000000).toStringAsFixed(1));
    }
    if (viewCount! >= 1000) {
      return loc.viewsK((viewCount! / 1000).toStringAsFixed(0));
    }
    return loc.viewsPlain(viewCount.toString());
  }

  String get durationFormatted {
    if (durationString != null && durationString!.isNotEmpty) return durationString!;
    if (duration == null || duration! <= 0) return '';
    final d = Duration(seconds: duration!);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  ExploreVideo copyWith({
    String? id,
    String? title,
    String? url,
    String? thumbnail,
    String? channel,
    String? channelId,
    int? duration,
    String? durationString,
    int? viewCount,
    String? viewsLabel,
    String? age,
    String? provider,
    int? resumeMs,
  }) {
    return ExploreVideo(
      id: id ?? this.id,
      title: title ?? this.title,
      url: url ?? this.url,
      thumbnail: thumbnail ?? this.thumbnail,
      channel: channel ?? this.channel,
      channelId: channelId ?? this.channelId,
      duration: duration ?? this.duration,
      durationString: durationString ?? this.durationString,
      viewCount: viewCount ?? this.viewCount,
      viewsLabel: viewsLabel ?? this.viewsLabel,
      age: age ?? this.age,
      provider: provider ?? this.provider,
    );
  }
}
