import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/theme/player_style.dart';

/// Global player style. One choice for every player surface (local library,
/// Explorer audio, mini player) so the app does not mix skins.
class PlayerStyleService extends ChangeNotifier {
  static final PlayerStyleService instance = PlayerStyleService._();
  PlayerStyleService._();

  static const _prefKey = 'vibegrab_player_style';

  PlayerStyle _style = PlayerStyle.classic;
  PlayerStyle get style => _style;

  bool _loaded = false;

  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _style = PlayerStyleInfo.parse(prefs.getString(_prefKey)) ??
          PlayerStyle.classic;
    } catch (_) {
      _style = PlayerStyle.classic;
    }
    notifyListeners();
  }

  Future<void> setStyle(PlayerStyle style) async {
    if (_style == style) return;
    _style = style;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, style.name);
    } catch (_) {
      // Persistence is best effort: the style still applies for this session.
    }
  }
}
