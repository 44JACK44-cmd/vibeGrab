class StreamUrls {
  final String? video;
  final String? audio;
  final String? title;
  final String? channel;
  final String? channelAvatar;
  final int? commentCount;
  final int? duration;
  final String? description;

  const StreamUrls({
    this.video,
    this.audio,
    this.title,
    this.channel,
    this.channelAvatar,
    this.commentCount,
    this.duration,
    this.description,
  });

  factory StreamUrls.fromJson(Map<String, dynamic> json) => StreamUrls(
        video: json['video'] as String?,
        audio: json['audio'] as String?,
        title: json['title'] as String?,
        channel: json['channel'] as String?,
        channelAvatar: json['channel_avatar'] as String?,
        commentCount: json['comment_count'] as int?,
        duration: json['duration'] as int?,
        description: json['description'] as String?,
      );
}
