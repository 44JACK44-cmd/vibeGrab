import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_colors.dart';

class ThemeProvider extends ChangeNotifier {
  static const _accentKey = 'vibegrab_accent_index';
  static const _themeModeKey = 'vibegrab_theme_mode';

  VibeAccent _accent = VibeAccent.accents[0];
  ThemeMode _themeMode = ThemeMode.dark;
  VibeAccent get accent => _accent;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode != ThemeMode.light;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final accentIndex = prefs.getInt(_accentKey) ?? 0;
    if (accentIndex >= 0 && accentIndex < VibeAccent.accents.length) {
      _accent = VibeAccent.accents[accentIndex];
    }
    final modeIndex = prefs.getInt(_themeModeKey) ?? 0;
    _themeMode = ThemeMode.values[modeIndex.clamp(0, ThemeMode.values.length - 1)];
    notifyListeners();
  }

  Future<void> setAccent(VibeAccent accent) async {
    _accent = accent;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentKey, VibeAccent.accents.indexOf(accent));
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeModeKey, ThemeMode.values.indexOf(mode));
  }

  void toggleDarkLight() {
    setThemeMode(_themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }
}
