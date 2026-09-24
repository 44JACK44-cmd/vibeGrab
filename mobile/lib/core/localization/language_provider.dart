import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LanguageProvider extends ChangeNotifier {
  static const _prefKey = 'vibegrab_language';
  Locale _locale = const Locale('es');
  String _mode = 'auto'; // 'auto', 'es', 'en'

  Locale get locale => _locale;
  String get mode => _mode;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _mode = prefs.getString(_prefKey) ?? 'auto';
    _applyMode();
  }

  void setLanguage(String mode) async {
    _mode = mode;
    _applyMode();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, mode);
    notifyListeners();
  }

  void _applyMode() {
    if (_mode == 'auto') {
      final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
      final supported = ['es', 'en'];
      if (supported.contains(deviceLocale.languageCode)) {
        _locale = deviceLocale;
      } else {
        _locale = const Locale('es');
      }
    } else {
      _locale = Locale(_mode);
    }
  }
}
