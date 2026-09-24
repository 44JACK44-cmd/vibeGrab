import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../data/models/app_settings.dart';
import '../../../services/storage_service.dart';

class SettingsController extends ChangeNotifier {
  SettingsController();

  AppSettings? _settings;
  AppSettings? get settings => _settings;

  bool _loading = false;
  bool get loading => _loading;

  Function(int)? onMaxConcurrentChanged;

  static const _prefix = 'vibegrab_setting_';

  Future<void> loadSettings() async {
    _loading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      _settings = AppSettings(
        downloadDir: StorageService.instance.downloadPath,
        maxConcurrentDownloads: prefs.getInt('${_prefix}max_concurrent') ?? 2,
        maxFileSizeMb: prefs.getInt('${_prefix}max_file_size') ?? 2048,
        autoOpenAfterDownload: prefs.getBool('${_prefix}auto_open') ?? false,
        preferBestQuality: prefs.getBool('${_prefix}prefer_best') ?? true,
        saveMetadata: prefs.getBool('${_prefix}save_metadata') ?? true,
      );
    } catch (_) {
      _settings = AppSettings(
        downloadDir: StorageService.instance.downloadPath,
        maxConcurrentDownloads: 2,
        maxFileSizeMb: 2048,
        autoOpenAfterDownload: false,
        preferBestQuality: true,
        saveMetadata: true,
      );
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> updateSetting({
    int? maxConcurrentDownloads,
    int? maxFileSizeMb,
    bool? autoOpenAfterDownload,
    bool? preferBestQuality,
    bool? saveMetadata,
  }) async {
    if (_settings == null) return;

    _settings = _settings!.copyWith(
      maxConcurrentDownloads: maxConcurrentDownloads,
      maxFileSizeMb: maxFileSizeMb,
      autoOpenAfterDownload: autoOpenAfterDownload,
      preferBestQuality: preferBestQuality,
      saveMetadata: saveMetadata,
    );
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      if (maxConcurrentDownloads != null) {
        await prefs.setInt('${_prefix}max_concurrent', maxConcurrentDownloads);
        onMaxConcurrentChanged?.call(maxConcurrentDownloads);
      }
      if (maxFileSizeMb != null) {
        await prefs.setInt('${_prefix}max_file_size', maxFileSizeMb);
      }
      if (autoOpenAfterDownload != null) {
        await prefs.setBool('${_prefix}auto_open', autoOpenAfterDownload);
      }
      if (preferBestQuality != null) {
        await prefs.setBool('${_prefix}prefer_best', preferBestQuality);
      }
      if (saveMetadata != null) {
        await prefs.setBool('${_prefix}save_metadata', saveMetadata);
      }
    } catch (_) {}
  }

  Future<String?> pickDownloadDirectory() async {
    final path = await StorageService.instance.pickDirectory();
    if (path != null && _settings != null) {
      _settings = _settings!.copyWith(downloadDir: path);
      notifyListeners();
    }
    return path;
  }
}
