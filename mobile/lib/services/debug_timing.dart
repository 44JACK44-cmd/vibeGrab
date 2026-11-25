import 'package:flutter/foundation.dart';

/// Minimal, honest timing helper: returns the duration since [stopwatch]
/// started, so callers can measure a stage and log it. Only active in
/// debug builds (`kDebugMode`), so nothing is added in release.
class DebugTiming {
  final Stopwatch stopwatch = Stopwatch()..start();

  Duration sinceStart() => stopwatch.elapsed;

  void log(String label, [Stopwatch? sw]) {
    final s = sw ?? stopwatch;
    debugPrint('[Timing] $label: ${s.elapsedMilliseconds} ms');
  }

  void restart() => stopwatch.reset();
}
