import 'package:flutter/services.dart';

/// Screen brightness for video playback (window attribute, -1 = system).
class DisplayService {
  static const _ch = MethodChannel('com.example.vibegrab/app');

  static Future<double> brightness() async {
    try {
      final v = await _ch.invokeMethod<double>('getBrightness');
      return v ?? -1.0;
    } catch (_) {
      return -1.0;
    }
  }

  static Future<void> setBrightness(double value) async {
    try {
      await _ch.invokeMethod('setBrightness', {'value': value.clamp(0.0, 1.0)});
    } catch (_) {}
  }

  static Future<void> resetBrightness() async {
    try {
      await _ch.invokeMethod('setBrightness', {'value': -1.0});
    } catch (_) {}
  }
}
