enum DownloadStatus { queued, preparing, resolving, connecting, downloading, saving, processing, completed, paused, cancelled, failed }

enum DownloadErrorType {
  storageNotConfigured,
  storageNotWritable,
  invalidUrl,
  formatNotFound,
  noStreams,
  streamsTimeout,
  streamsFailed,
  urlNull,
  httpError,
  http403,
  connectionTimeout,
  serverTimeout,
  connectionFailed,
  fileEmpty,
  muxNoAudio,
  cancelled,
  generic,
}

enum DownloadMediaType { video, audio }

class DownloadTask {
  final String id;
  final String url;
  final String title;
  final String formatId;
  final String? thumbnail;
  final String? source;
  final bool hasVideo;
  final bool hasAudio;
  final DownloadMediaType mediaType;
  final String? directUrl;
  final String? fileExt;
  DownloadStatus status;
  double progress;
  int bytesDownloaded;
  int? totalBytes;
  String? filePath;
  String? error;
  DownloadErrorType? errorCode;
  String? step;
  int retryCount;
  final String createdAt;
  String? startedAt;
  String? completedAt;

  DownloadTask({
    required this.id,
    required this.url,
    required this.title,
    required this.formatId,
    this.thumbnail,
    this.source,
    this.hasVideo = true,
    this.hasAudio = true,
    this.mediaType = DownloadMediaType.video,
    this.directUrl,
    this.fileExt,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes,
    this.filePath,
    this.error,
    this.errorCode,
    this.step,
    this.retryCount = 0,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
  });

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    return DownloadTask(
      id: json['id'] ?? '',
      url: json['url'] ?? '',
      title: json['title'] ?? 'Untitled',
      formatId: json['format_id'] ?? '',
      thumbnail: json['thumbnail'],
      source: json['source'],
      hasVideo: json['has_video'] ?? true,
      hasAudio: json['has_audio'] ?? true,
      mediaType: DownloadMediaType.values.firstWhere(
        (e) => e.name == json['media_type'],
        orElse: () => DownloadMediaType.video,
      ),
      directUrl: json['direct_url'],
      fileExt: json['file_ext'],
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == json['status'],
        orElse: () => DownloadStatus.queued,
      ),
      progress: (json['progress'] ?? 0).toDouble(),
      bytesDownloaded: json['bytes_downloaded'] ?? 0,
      totalBytes: json['total_bytes'],
      filePath: json['file_path'],
      error: json['error'],
      errorCode: json['error_code'] != null
          ? DownloadErrorType.values.firstWhere(
              (e) => e.name == json['error_code'],
              orElse: () => DownloadErrorType.generic,
            )
          : null,
      step: json['step'],
      retryCount: json['retry_count'] ?? 0,
      createdAt: json['created_at'] ?? '',
      startedAt: json['started_at'],
      completedAt: json['completed_at'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'format_id': formatId,
      'thumbnail': thumbnail,
      'source': source,
      'has_video': hasVideo,
      'has_audio': hasAudio,
      'media_type': mediaType.name,
      'direct_url': directUrl,
      'file_ext': fileExt,
      'status': status.name,
      'progress': progress,
      'bytes_downloaded': bytesDownloaded,
      'total_bytes': totalBytes,
      'file_path': filePath,
      'error': error,
      'error_code': errorCode?.name,
      'step': step,
      'retry_count': retryCount,
      'created_at': createdAt,
      'started_at': startedAt,
      'completed_at': completedAt,
    };
  }

  static const Object _sentinel = Object();

  DownloadTask copyWith({
    String? status,
    double? progress,
    int? bytesDownloaded,
    Object? totalBytes = _sentinel,
    Object? filePath = _sentinel,
    Object? error = _sentinel,
    String? errorCode,
    Object? step = _sentinel,
    int? retryCount,
    Object? startedAt = _sentinel,
    Object? completedAt = _sentinel,
    DownloadMediaType? mediaType,
  }) {
    return DownloadTask(
      id: id,
      url: url,
      title: title,
      formatId: formatId,
      thumbnail: thumbnail,
      source: source,
      hasVideo: hasVideo,
      hasAudio: hasAudio,
      mediaType: mediaType ?? this.mediaType,
      directUrl: directUrl,
      fileExt: fileExt,
      status: status != null
          ? DownloadStatus.values.firstWhere((e) => e.name == status, orElse: () => this.status)
          : this.status,
      progress: progress ?? this.progress,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      totalBytes: identical(totalBytes, _sentinel) ? this.totalBytes : totalBytes as int?,
      filePath: identical(filePath, _sentinel) ? this.filePath : filePath as String?,
      error: identical(error, _sentinel) ? this.error : error as String?,
      errorCode: errorCode != null
          ? DownloadErrorType.values.firstWhere((e) => e.name == errorCode, orElse: () => this.errorCode ?? DownloadErrorType.generic)
          : this.errorCode,
      step: identical(step, _sentinel) ? this.step : step as String?,
      retryCount: retryCount ?? this.retryCount,
      createdAt: createdAt,
      startedAt: identical(startedAt, _sentinel) ? this.startedAt : startedAt as String?,
      completedAt: identical(completedAt, _sentinel) ? this.completedAt : completedAt as String?,
    );
  }

  bool get isActive =>
      status == DownloadStatus.downloading ||
      status == DownloadStatus.preparing ||
      status == DownloadStatus.resolving ||
      status == DownloadStatus.connecting ||
      status == DownloadStatus.processing ||
      status == DownloadStatus.saving ||
      status == DownloadStatus.queued;

  String get progressFormatted => '${(progress * 100).toStringAsFixed(0)}%';

  String get sizeFormatted {
    if (totalBytes == null) return '';
    if (totalBytes! < 1024 * 1024) {
      return '${(totalBytes! / 1024).toStringAsFixed(0)} KB';
    }
    return '${(totalBytes! / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get speedFormatted {
    if (bytesDownloaded == 0 || startedAt == null) return '';
    final elapsed = DateTime.now().difference(DateTime.parse(startedAt!)).inSeconds;
    if (elapsed <= 0) return '';
    final speed = bytesDownloaded / elapsed;
    if (speed < 1024 * 1024) return '${(speed / 1024).toStringAsFixed(0)} KB/s';
    return '${(speed / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}
