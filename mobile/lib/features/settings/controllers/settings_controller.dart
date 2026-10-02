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

  Future<void> loadSettings() async {
    _loading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      _settings = AppSettings(
        downloadDir: StorageService.instance.downloadPath,
        maxConcurrentDownloads: prefs.getInt(AppSettingKeys.maxConcurrent) ?? 2,
        maxFileSizeMb: prefs.getInt(AppSettingKeys.maxFileSize) ?? 2048,
        autoOpenAfterDownload: prefs.getBool(AppSettingKeys.autoOpen) ?? false,
        preferBestQuality: prefs.getBool(AppSettingKeys.preferBest) ?? true,
        saveMetadata: prefs.getBool(AppSettingKeys.saveMetadata) ?? true,
        defaultQuality: prefs.getString(AppSettingKeys.defaultQuality) ?? '720p',
        speedLimitKbps: prefs.getInt(AppSettingKeys.speedLimitKbps) ?? 0,
        notifyCompleted: prefs.getBool(AppSettingKeys.notifyCompleted) ?? true,
        notifyErrors: prefs.getBool(AppSettingKeys.notifyErrors) ?? true,
        notifySound: prefs.getBool(AppSettingKeys.notifySound) ?? true,
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
    String? defaultQuality,
    int? speedLimitKbps,
    bool? notifyCompleted,
    bool? notifyErrors,
    bool? notifySound,
  }) async {
    if (_settings == null) return;

    _settings = _settings!.copyWith(
      maxConcurrentDownloads: maxConcurrentDownloads,
      maxFileSizeMb: maxFileSizeMb,
      autoOpenAfterDownload: autoOpenAfterDownload,
      preferBestQuality: preferBestQuality,
      saveMetadata: saveMetadata,
      defaultQuality: defaultQuality,
      speedLimitKbps: speedLimitKbps,
      notifyCompleted: notifyCompleted,
      notifyErrors: notifyErrors,
      notifySound: notifySound,
    );
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      if (maxConcurrentDownloads != null) {
        await prefs.setInt(AppSettingKeys.maxConcurrent, maxConcurrentDownloads);
        onMaxConcurrentChanged?.call(maxConcurrentDownloads);
      }
      if (maxFileSizeMb != null) {
        await prefs.setInt(AppSettingKeys.maxFileSize, maxFileSizeMb);
      }
      if (autoOpenAfterDownload != null) {
        await prefs.setBool(AppSettingKeys.autoOpen, autoOpenAfterDownload);
      }
      if (preferBestQuality != null) {
        await prefs.setBool(AppSettingKeys.preferBest, preferBestQuality);
      }
      if (saveMetadata != null) {
        await prefs.setBool(AppSettingKeys.saveMetadata, saveMetadata);
      }
      if (defaultQuality != null) {
        await prefs.setString(AppSettingKeys.defaultQuality, defaultQuality);
      }
      if (speedLimitKbps != null) {
        await prefs.setInt(AppSettingKeys.speedLimitKbps, speedLimitKbps);
      }
      if (notifyCompleted != null) {
        await prefs.setBool(AppSettingKeys.notifyCompleted, notifyCompleted);
      }
      if (notifyErrors != null) {
        await prefs.setBool(AppSettingKeys.notifyErrors, notifyErrors);
      }
      if (notifySound != null) {
        await prefs.setBool(AppSettingKeys.notifySound, notifySound);
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
