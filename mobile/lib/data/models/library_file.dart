class LibraryFile {
  final String filename;
  final String title;
  final String filePath;
  final int fileSize;
  final String fileSizeFormatted;
  final String fileType;
  final String extension;
  final String createdAt;
  final String? thumbnail;
  final String? thumbnailPath;
  final String? source;
  final String sourceType;
  final String? contentUri;
  final String? album;
  final String? artist;
  final int? durationMs;

  LibraryFile({
    required this.filename,
    required this.title,
    required this.filePath,
    required this.fileSize,
    required this.fileSizeFormatted,
    required this.fileType,
    required this.extension,
    required this.createdAt,
    this.thumbnail,
    this.thumbnailPath,
    this.source,
    this.sourceType = 'downloaded',
    this.contentUri,
    this.album,
    this.artist,
    this.durationMs,
  });

  factory LibraryFile.fromJson(Map<String, dynamic> json) {
    return LibraryFile(
      filename: json['filename'] ?? '',
      title: json['title'] ?? 'Untitled',
      filePath: json['file_path'] ?? json['filePath'] ?? '',
      fileSize: json['file_size'] ?? json['fileSize'] ?? 0,
      fileSizeFormatted: json['file_size_formatted'] ?? json['fileSizeFormatted'] ?? '',
      fileType: json['file_type'] ?? json['fileType'] ?? 'unknown',
      extension: json['extension'] ?? '',
      createdAt: json['created_at'] ?? json['createdAt'] ?? '',
      thumbnail: json['thumbnail'],
      thumbnailPath: json['thumbnailPath'],
      source: json['source'],
      sourceType: json['source_type'] ?? json['sourceType'] ?? 'downloaded',
      contentUri: json['contentUri'] ?? json['content_uri'],
      album: json['album'],
      artist: json['artist'],
      durationMs: json['duration'] != null ? (json['duration'] is int ? json['duration'] : int.tryParse('${json['duration']}')) : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'filename': filename,
      'title': title,
      'filePath': filePath,
      'fileSize': fileSize,
      'fileSizeFormatted': fileSizeFormatted,
      'fileType': fileType,
      'extension': extension,
      'createdAt': createdAt,
      'thumbnail': thumbnail,
      'thumbnailPath': thumbnailPath,
      'source': source,
      'sourceType': sourceType,
      'contentUri': contentUri,
      'album': album,
      'artist': artist,
      'duration': durationMs,
    };
  }

  bool get isVideo => fileType == 'video';
  bool get isAudio => fileType == 'audio';
  bool get isLocal => sourceType == 'local';
  bool get isDownloaded => sourceType == 'downloaded';
  bool get hasContentUri => contentUri != null && contentUri!.isNotEmpty;

  String? get displayUri => contentUri ?? (filePath.isNotEmpty ? filePath : null);
}
