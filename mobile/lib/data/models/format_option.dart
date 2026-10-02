class FormatOption {
  final String id;
  final String type;
  final String extension;
  final String? quality;
  final bool hasVideo;
  final bool hasAudio;
  final int? sizeBytes;
  final String? directUrl;

  FormatOption({
    required this.id,
    required this.type,
    required this.extension,
    this.quality,
    required this.hasVideo,
    required this.hasAudio,
    this.sizeBytes,
    this.directUrl,
  });

  factory FormatOption.fromJson(Map<String, dynamic> json) {
    return FormatOption(
      id: json['id'] ?? '',
      type: json['type'] ?? 'video',
      extension: json['extension'] ?? 'mp4',
      quality: json['quality'],
      hasVideo: json['has_video'] ?? false,
      hasAudio: json['has_audio'] ?? false,
      sizeBytes: json['size_bytes'],
      directUrl: json['direct_url'],
    );
  }

  String get label {
    if (type == 'audio') {
      final size = sizeBytes != null ? ' \u2022 ${formatSize(sizeBytes!)}' : '';
      return '${quality ?? extension} \u2022 ${extension.toUpperCase()}$size';
    }
    final q = quality ?? '';
    final codec = hasAudio ? '' : ' (no audio)';
    final size = sizeBytes != null ? ' \u2022 ${formatSize(sizeBytes!)}' : '';
    return '$q \u2022 ${extension.toUpperCase()}$codec$size';
  }

  String get subtitle {
    if (type == 'audio') return 'Music \u2014 ${hasAudio ? 'con audio' : ''}';
    if (hasVideo && hasAudio) return 'Video with audio';
    if (hasVideo && !hasAudio) return 'Video only (no audio)';
    return '';
  }

  String get typeLabel => type == 'audio' ? 'AUDIO' : 'VIDEO';

  static String formatSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
