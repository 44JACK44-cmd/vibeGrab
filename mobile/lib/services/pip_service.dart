import 'dart:async';
import 'package:flutter/services.dart';

class PiPService {
  static const _channel = MethodChannel('com.example.vibegrab/pip');
  static final StreamController<bool> _pipController = StreamController<bool>.broadcast();

  static Stream<bool> get onPiPChanged => _pipController.stream;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onPipModeChanged') {
        final isInPip = call.arguments['isInPip'] as bool? ?? false;
        _pipController.add(isInPip);
      }
    });
  }

  static Future<bool> isAvailable() async {
    try {
      final result = await _channel.invokeMethod<bool>('isPipAvailable');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> enterPiP() async {
    try {
      final result = await _channel.invokeMethod<bool>('enterPip');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isInPiP() async {
    try {
      final result = await _channel.invokeMethod<bool>('isInPip');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }
}
