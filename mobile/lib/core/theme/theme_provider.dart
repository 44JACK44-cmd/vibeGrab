import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_colors.dart';
import 'vibe_presets.dart';

class ThemeProvider extends ChangeNotifier {
  static const _accentKey = 'vibegrab_accent_index';
  static const _themeModeKey = 'vibegrab_theme_mode';
  static const _presetKey = 'vibegrab_theme_preset';

  VibeAccent _accent = VibeAccent.accents[0];
  VibePreset _preset = VibePreset.presets[0];
  bool _customAccent = false;
  ThemeMode _themeMode = ThemeMode.dark;
  VibeAccent get accent => _accent;
  VibePreset get preset => _preset;
  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode != ThemeMode.light;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final accentIndex = prefs.getInt(_accentKey) ?? 0;
    if (accentIndex >= 0 && accentIndex < VibeAccent.accents.length) {
      _accent = VibeAccent.accents[accentIndex];
    }
    _preset = VibePreset.byId(prefs.getString(_presetKey) ?? 'classic');
    // A preset carries its own accent unless the user picked a custom one.
    _customAccent = prefs.getBool('vibegrab_custom_accent') ?? false;
    if (!_customAccent) _accent = VibeAccent(name: 'preset', color: _preset.accent);
    final modeIndex = prefs.getInt(_themeModeKey) ?? 0;
    _themeMode = ThemeMode.values[modeIndex.clamp(0, ThemeMode.values.length - 1)];
    notifyListeners();
  }

  Future<void> setAccent(VibeAccent accent) async {
    _accent = accent;
    _customAccent = true;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_accentKey, VibeAccent.accents.indexOf(accent));
    await prefs.setBool('vibegrab_custom_accent', true);
  }

  Future<void> setPreset(VibePreset preset) async {
    _preset = preset;
    _accent = VibeAccent(name: 'preset', color: preset.accent);
    _customAccent = false;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_presetKey, preset.id);
    await prefs.setBool('vibegrab_custom_accent', false);
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
