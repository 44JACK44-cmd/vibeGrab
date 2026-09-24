class AppSettings {
  final String downloadDir;
  final int maxConcurrentDownloads;
  final int maxFileSizeMb;
  final bool autoOpenAfterDownload;
  final bool preferBestQuality;
  final bool saveMetadata;

  AppSettings({
    required this.downloadDir,
    required this.maxConcurrentDownloads,
    required this.maxFileSizeMb,
    required this.autoOpenAfterDownload,
    required this.preferBestQuality,
    required this.saveMetadata,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      downloadDir: json['download_dir'] ?? '',
      maxConcurrentDownloads: json['max_concurrent_downloads'] ?? 2,
      maxFileSizeMb: json['max_file_size_mb'] ?? 2048,
      autoOpenAfterDownload: json['auto_open_after_download'] ?? false,
      preferBestQuality: json['prefer_best_quality'] ?? true,
      saveMetadata: json['save_metadata'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'download_dir': downloadDir,
        'max_concurrent_downloads': maxConcurrentDownloads,
        'max_file_size_mb': maxFileSizeMb,
        'auto_open_after_download': autoOpenAfterDownload,
        'prefer_best_quality': preferBestQuality,
        'save_metadata': saveMetadata,
      };

  AppSettings copyWith({
    String? downloadDir,
    int? maxConcurrentDownloads,
    int? maxFileSizeMb,
    bool? autoOpenAfterDownload,
    bool? preferBestQuality,
    bool? saveMetadata,
  }) {
    return AppSettings(
      downloadDir: downloadDir ?? this.downloadDir,
      maxConcurrentDownloads: maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      maxFileSizeMb: maxFileSizeMb ?? this.maxFileSizeMb,
      autoOpenAfterDownload: autoOpenAfterDownload ?? this.autoOpenAfterDownload,
      preferBestQuality: preferBestQuality ?? this.preferBestQuality,
      saveMetadata: saveMetadata ?? this.saveMetadata,
    );
  }
}
