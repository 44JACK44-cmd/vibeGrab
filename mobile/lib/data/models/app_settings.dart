class AppSettingKeys {
  static const prefix = 'vibegrab_setting_';
  static const maxConcurrent = '${prefix}max_concurrent';
  static const maxFileSize = '${prefix}max_file_size';
  static const autoOpen = '${prefix}auto_open';
  static const preferBest = '${prefix}prefer_best';
  static const saveMetadata = '${prefix}save_metadata';
  static const defaultQuality = '${prefix}default_quality';
  static const speedLimitKbps = '${prefix}speed_limit_kbps';
  static const notifyCompleted = '${prefix}notify_completed';
  static const notifyErrors = '${prefix}notify_errors';
  static const notifySound = '${prefix}notify_sound';
}

class AppSettings {
  final String downloadDir;
  final int maxConcurrentDownloads;
  final int maxFileSizeMb;
  final bool autoOpenAfterDownload;
  final bool preferBestQuality;
  final bool saveMetadata;
  final String defaultQuality;
  final int speedLimitKbps;
  final bool notifyCompleted;
  final bool notifyErrors;
  final bool notifySound;

  AppSettings({
    required this.downloadDir,
    required this.maxConcurrentDownloads,
    required this.maxFileSizeMb,
    required this.autoOpenAfterDownload,
    required this.preferBestQuality,
    required this.saveMetadata,
    this.defaultQuality = '720p',
    this.speedLimitKbps = 0,
    this.notifyCompleted = true,
    this.notifyErrors = true,
    this.notifySound = true,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      downloadDir: json['download_dir'] ?? '',
      maxConcurrentDownloads: json['max_concurrent_downloads'] ?? 2,
      maxFileSizeMb: json['max_file_size_mb'] ?? 2048,
      autoOpenAfterDownload: json['auto_open_after_download'] ?? false,
      preferBestQuality: json['prefer_best_quality'] ?? true,
      saveMetadata: json['save_metadata'] ?? true,
      defaultQuality: json['default_quality'] ?? '720p',
      speedLimitKbps: json['speed_limit_kbps'] ?? 0,
      notifyCompleted: json['notify_completed'] ?? true,
      notifyErrors: json['notify_errors'] ?? true,
      notifySound: json['notify_sound'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'download_dir': downloadDir,
        'max_concurrent_downloads': maxConcurrentDownloads,
        'max_file_size_mb': maxFileSizeMb,
        'auto_open_after_download': autoOpenAfterDownload,
        'prefer_best_quality': preferBestQuality,
        'save_metadata': saveMetadata,
        'default_quality': defaultQuality,
        'speed_limit_kbps': speedLimitKbps,
        'notify_completed': notifyCompleted,
        'notify_errors': notifyErrors,
        'notify_sound': notifySound,
      };

  AppSettings copyWith({
    String? downloadDir,
    int? maxConcurrentDownloads,
    int? maxFileSizeMb,
    bool? autoOpenAfterDownload,
    bool? preferBestQuality,
    bool? saveMetadata,
    String? defaultQuality,
    int? speedLimitKbps,
    bool? notifyCompleted,
    bool? notifyErrors,
    bool? notifySound,
  }) {
    return AppSettings(
      downloadDir: downloadDir ?? this.downloadDir,
      maxConcurrentDownloads: maxConcurrentDownloads ?? this.maxConcurrentDownloads,
      maxFileSizeMb: maxFileSizeMb ?? this.maxFileSizeMb,
      autoOpenAfterDownload: autoOpenAfterDownload ?? this.autoOpenAfterDownload,
      preferBestQuality: preferBestQuality ?? this.preferBestQuality,
      saveMetadata: saveMetadata ?? this.saveMetadata,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      speedLimitKbps: speedLimitKbps ?? this.speedLimitKbps,
      notifyCompleted: notifyCompleted ?? this.notifyCompleted,
      notifyErrors: notifyErrors ?? this.notifyErrors,
      notifySound: notifySound ?? this.notifySound,
    );
  }
}
