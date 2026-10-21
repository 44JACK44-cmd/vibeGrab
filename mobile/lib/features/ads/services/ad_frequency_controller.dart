import 'package:shared_preferences/shared_preferences.dart';

import '../config/ad_config.dart';

/// Persistence boundary for the last interstitial timestamp.
///
/// The app only stores a timestamp, never URLs, media titles or identifiers.
abstract class AdFrequencyStore {
  Future<DateTime?> readLastInterstitial();
  Future<void> writeLastInterstitial(DateTime value);
}

class SharedPreferencesAdFrequencyStore implements AdFrequencyStore {
  static const String _lastInterstitialKey = 'ads.last_interstitial_ms';

  @override
  Future<DateTime?> readLastInterstitial() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final millis = prefs.getInt(_lastInterstitialKey);
      if (millis == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeLastInterstitial(DateTime value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastInterstitialKey, value.millisecondsSinceEpoch);
    } catch (_) {
      // Persistence is an optimisation; losing the timestamp must never crash
      // the app or block playback/downloads.
    }
  }
}

class MemoryAdFrequencyStore implements AdFrequencyStore {
  MemoryAdFrequencyStore({DateTime? lastInterstitial})
    : _lastInterstitial = lastInterstitial;

  DateTime? _lastInterstitial;

  @override
  Future<DateTime?> readLastInterstitial() async => _lastInterstitial;

  @override
  Future<void> writeLastInterstitial(DateTime value) async {
    _lastInterstitial = value;
  }
}

/// Shared, session-aware interstitial limiter.
///
/// Product limits are intentionally conservative: at most one interstitial
/// every ten minutes, three per session, and none during the first minute. The
/// class only decides frequency; [AdPolicy] decides whether the current app
/// state is safe enough to show anything at all.
class AdFrequencyController {
  AdFrequencyController({
    required DateTime sessionStart,
    AdFrequencyStore? store,
  }) : _sessionStart = sessionStart,
       _store = store ?? SharedPreferencesAdFrequencyStore();

  final DateTime _sessionStart;
  final AdFrequencyStore _store;

  DateTime? _lastInterstitialAt;
  int _sessionInterstitialCount = 0;
  bool _initialized = false;

  int get sessionInterstitialCount => _sessionInterstitialCount;
  DateTime? get lastInterstitialAt => _lastInterstitialAt;

  Future<void> init() async {
    if (_initialized) return;
    _lastInterstitialAt = await _store.readLastInterstitial();
    _initialized = true;
  }

  bool canShowInterstitial({
    required DateTime now,
    Duration cooldown = AdConfig.interstitialCooldown,
    Duration sessionGrace = AdConfig.interstitialSessionGrace,
    int maxPerSession = AdConfig.maxInterstitialsPerSession,
  }) {
    if (_sessionInterstitialCount >= maxPerSession) return false;
    if (now.difference(_sessionStart) < sessionGrace) return false;

    final last = _lastInterstitialAt;
    if (last != null &&
        !now.isBefore(last) &&
        now.difference(last) < cooldown) {
      return false;
    }
    return true;
  }

  Future<void> noteInterstitialShown(DateTime now) async {
    _lastInterstitialAt = now;
    _sessionInterstitialCount += 1;
    await _store.writeLastInterstitial(now);
  }
}
