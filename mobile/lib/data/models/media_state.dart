enum MediaStatus { idle, loading, buffering, playing, paused, completed }

enum MediaType { audio, video }

enum PlayerRepeatMode { none, one, all }

class MediaState {
  final MediaStatus status;
  final String? mediaId;
  final String? title;
  final String? artist;
  final String? thumbnail;
  final String? thumbnailPath;
  final Duration position;
  final Duration duration;
  final MediaType? mediaType;
  final bool isShuffle;
  final PlayerRepeatMode repeatMode;

  MediaState({
    this.status = MediaStatus.idle,
    this.mediaId,
    this.title,
    this.artist,
    this.thumbnail,
    this.thumbnailPath,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.mediaType,
    this.isShuffle = false,
    this.repeatMode = PlayerRepeatMode.none,
  });

  bool get isPlaying => status == MediaStatus.playing;
  bool get isPaused => status == MediaStatus.paused;
  bool get isIdle => status == MediaStatus.idle;
  bool get hasMedia => mediaId != null;

  MediaState copyWith({
    MediaStatus? status,
    String? mediaId,
    String? title,
    String? artist,
    String? thumbnail,
    String? thumbnailPath,
    Duration? position,
    Duration? duration,
    MediaType? mediaType,
    bool? isShuffle,
    PlayerRepeatMode? repeatMode,
  }) {
    return MediaState(
      status: status ?? this.status,
      mediaId: mediaId ?? this.mediaId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      thumbnail: thumbnail ?? this.thumbnail,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      mediaType: mediaType ?? this.mediaType,
      isShuffle: isShuffle ?? this.isShuffle,
      repeatMode: repeatMode ?? this.repeatMode,
    );
  }
}
