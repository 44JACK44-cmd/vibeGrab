import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real DSP equalizer (Android audiofx) bound to the player's audio session.
///
/// Persists enabled / bands / preset / bass / loudness and re-applies them
/// whenever a new audio session appears. Session id 0 = output mix (video).
class EqualizerService extends ChangeNotifier {
  static final EqualizerService instance = EqualizerService._();
  EqualizerService._();

  static const _ch = MethodChannel('com.example.vibegrab/equalizer');

  bool available = false;
  bool enabled = false;
  int bandCount = 0;
  int minMb = -1500;
  int maxMb = 1500;
  List<int> freqsHz = const [];
  List<String> presets = const [];

  /// Levels in millibels, per band. Empty until the native side reports.
  List<int> levelsMb = [];
  int presetIndex = -1; // -1 = custom
  int bass = 0; // 0..100
  int loudness = 0; // 0..100 (mapped to 0..700 mB target gain)

  int? _sessionId;
  bool _loaded = false;

  Future<void> _loadPrefs() async {
    if (_loaded) return;
    _loaded = true;
    final p = await SharedPreferences.getInstance();
    enabled = p.getBool('vibegrab_eq_enabled') ?? false;
    presetIndex = p.getInt('vibegrab_eq_preset') ?? -1;
    bass = (p.getInt('vibegrab_eq_bass') ?? 0).clamp(0, 100);
    loudness = (p.getInt('vibegrab_eq_loud') ?? 0).clamp(0, 100);
    final lv = p.getStringList('vibegrab_eq_levels');
    if (lv != null) {
      levelsMb = lv.map((e) => int.tryParse(e) ?? 0).toList();
    }
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('vibegrab_eq_enabled', enabled);
    await p.setInt('vibegrab_eq_preset', presetIndex);
    await p.setInt('vibegrab_eq_bass', bass);
    await p.setInt('vibegrab_eq_loud', loudness);
    await p.setStringList(
        'vibegrab_eq_levels', levelsMb.map((e) => e.toString()).toList());
  }

  /// Attaches the DSP to [sessionId] (0 = output mix) and re-applies the
  /// stored curve. Idempotent per session: calling it on every play is safe.
  Future<void> ensureReady(int? sessionId) async {
    await _loadPrefs();
    final sid = sessionId ?? 0;
    try {
      final ok = await _ch.invokeMethod<bool>('init', {
        'sessionId': sid,
        'enabled': enabled,
      });
      if (ok != true) {
        available = false;
        notifyListeners();
        return;
      }
      _sessionId = sid;
      final info = await _ch.invokeMethod<Map<Object?, Object?>>('info');
      if (info != null && info['ok'] == true) {
        available = true;
        bandCount = (info['bands'] as int?) ?? 0;
        minMb = (info['minMb'] as int?) ?? -1500;
        maxMb = (info['maxMb'] as int?) ?? 1500;
        freqsHz = ((info['freqs'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList();
        presets = ((info['presets'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        if (levelsMb.length != bandCount) {
          levelsMb = List<int>.filled(bandCount, 0);
        }
        await _applyAll();
      } else {
        available = false;
      }
    } catch (e) {
      debugPrint('[EQ] ensureReady failed: $e');
      available = false;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    await _loadPrefs();
    enabled = v;
    await _savePrefs();
    try {
      await _ch.invokeMethod('setEnabled', {'enabled': v});
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setBand(int band, int levelMb) async {
    if (band < 0 || band >= bandCount) return;
    final clamped = levelMb.clamp(minMb, maxMb);
    if (levelsMb.length == bandCount) levelsMb[band] = clamped;
    presetIndex = -1; // manual touch => custom curve
    await _savePrefs();
    try {
      await _ch.invokeMethod('setBand', {'band': band, 'levelMb': clamped});
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setPreset(int index) async {
    if (index < 0 || index >= presets.length) return;
    presetIndex = index;
    await _savePrefs();
    try {
      await _ch.invokeMethod('setPreset', {'index': index});
    } catch (_) {}
    await _readbackLevels();
    notifyListeners();
  }

  Future<void> setBass(int v) async {
    bass = v.clamp(0, 100);
    await _savePrefs();
    try {
      await _ch.invokeMethod('setBass', {'strength': bass * 10});
    } catch (_) {}
    notifyListeners();
  }

  Future<void> setLoudness(int v) async {
    loudness = v.clamp(0, 100);
    await _savePrefs();
    try {
      await _ch.invokeMethod('setLoudness', {'gainMb': loudness * 7});
    } catch (_) {}
    notifyListeners();
  }

  Future<void> _applyAll() async {
    try {
      await _ch.invokeMethod('setEnabled', {'enabled': enabled});
      if (presetIndex >= 0 && presetIndex < presets.length) {
        await _ch.invokeMethod('setPreset', {'index': presetIndex});
      } else {
        for (var i = 0; i < levelsMb.length && i < bandCount; i++) {
          await _ch.invokeMethod(
              'setBand', {'band': i, 'levelMb': levelsMb[i]});
        }
      }
      await _ch.invokeMethod('setBass', {'strength': bass * 10});
      await _ch.invokeMethod('setLoudness', {'gainMb': loudness * 7});
    } catch (_) {}
  }

  /// After a preset change the DSP owns the curve: pull levels back so the
  /// sliders reflect reality.
  Future<void> _readbackLevels() async {
    // Android does not expose preset curves; keep sliders neutral and let
    // the next manual touch define the custom curve from current device state.
    if (levelsMb.length == bandCount) {
      levelsMb = List<int>.filled(bandCount, 0);
    }
  }

  int? get sessionId => _sessionId;
}
