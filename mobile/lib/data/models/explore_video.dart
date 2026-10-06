import '../../core/localization/app_localizations.dart';

class ExploreVideo {
  final String id;
  final String title;
  final String url;
  final String? thumbnail;
  final String? channel;
  final int? duration;
  final String? durationString;
  final int? viewCount;
  final String? viewsLabel;
  final String? age;

  const ExploreVideo({
    required this.id,
    required this.title,
    required this.url,
    this.thumbnail,
    this.channel,
    this.duration,
    this.durationString,
    this.viewCount,
    this.viewsLabel,
    this.age,
  });

  factory ExploreVideo.fromJson(Map<String, dynamic> json) {
    return ExploreVideo(
      id: json['id'] ?? '',
      title: json['title'] ?? 'Untitled',
      url: json['url'] ?? '',
      thumbnail: json['thumbnail'],
      channel: json['channel'],
      duration: json['duration'],
      durationString: json['duration_string'],
      viewCount: json['view_count'],
      viewsLabel: json['views_label'],
      age: json['age'],
    );
  }

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
}
