import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/ads/services/ad_frequency_controller.dart';

void main() {
  final sessionStart = DateTime(2026, 1, 1, 12);

  test('enforces the one-minute grace period', () {
    final controller = AdFrequencyController(
      sessionStart: sessionStart,
      store: MemoryAdFrequencyStore(),
    );

    expect(
      controller.canShowInterstitial(
        now: sessionStart.add(const Duration(seconds: 59)),
      ),
      isFalse,
    );
    expect(
      controller.canShowInterstitial(
        now: sessionStart.add(const Duration(seconds: 60)),
      ),
      isTrue,
    );
  });

  test('enforces ten-minute cooldown and three per session', () async {
    final controller = AdFrequencyController(
      sessionStart: sessionStart,
      store: MemoryAdFrequencyStore(),
    );
    var now = sessionStart.add(const Duration(seconds: 60));

    expect(controller.canShowInterstitial(now: now), isTrue);
    await controller.noteInterstitialShown(now);
    expect(controller.canShowInterstitial(now: now), isFalse);

    now = now.add(const Duration(minutes: 10));
    expect(controller.canShowInterstitial(now: now), isTrue);
    await controller.noteInterstitialShown(now);

    now = now.add(const Duration(minutes: 10));
    expect(controller.canShowInterstitial(now: now), isTrue);
    await controller.noteInterstitialShown(now);
    expect(controller.sessionInterstitialCount, 3);

    now = now.add(const Duration(minutes: 10));
    expect(controller.canShowInterstitial(now: now), isFalse);
  });

  test('reads a persisted cooldown when the session restarts', () async {
    final last = sessionStart.subtract(const Duration(minutes: 2));
    final store = MemoryAdFrequencyStore(lastInterstitial: last);
    final controller = AdFrequencyController(
      sessionStart: sessionStart,
      store: store,
    );
    await controller.init();

    expect(
      controller.canShowInterstitial(
        now: sessionStart.add(const Duration(seconds: 60)),
      ),
      isFalse,
    );
  });

  test('falls back to a fresh limiter when persisted data is unavailable', () {
    final controller = AdFrequencyController(
      sessionStart: sessionStart,
      store: MemoryAdFrequencyStore(),
    );
    expect(controller.lastInterstitialAt, isNull);
    expect(
      controller.canShowInterstitial(
        now: sessionStart.add(const Duration(seconds: 60)),
      ),
      isTrue,
    );
  });
}
