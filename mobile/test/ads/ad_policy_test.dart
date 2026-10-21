import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/ads/models/ad_placement.dart';
import 'package:vibegrab/features/ads/services/ad_frequency_controller.dart';
import 'package:vibegrab/features/ads/services/ad_policy.dart';

void main() {
  final sessionStart = DateTime(2026, 1, 1, 12);
  late AdFrequencyController frequency;

  setUp(() {
    frequency = AdFrequencyController(
      sessionStart: sessionStart,
      store: MemoryAdFrequencyStore(),
    );
  });

  AdPolicy policy() => AdPolicy(
    frequency: frequency,
    sessionStart: sessionStart,
    bannerInitialDelay: const Duration(seconds: 20),
    interstitialSessionGrace: const Duration(seconds: 60),
  );

  group('approved placements', () {
    test(
      'home, browser and library are approved; analyser/settings are not',
      () {
        expect(
          AdPlacement.forTab(0, downloadsActive: false),
          AdPlacement.homeBanner,
        );
        expect(
          AdPlacement.forTab(1, downloadsActive: false),
          AdPlacement.browserBanner,
        );
        expect(AdPlacement.forTab(2, downloadsActive: false), isNull);
        expect(
          AdPlacement.forTab(4, downloadsActive: false),
          AdPlacement.libraryBanner,
        );
        expect(AdPlacement.forTab(5, downloadsActive: false), isNull);
      },
    );

    test('downloads slot disappears while a task is active', () {
      expect(
        AdPlacement.forTab(3, downloadsActive: false),
        AdPlacement.downloadsBanner,
      );
      expect(AdPlacement.forTab(3, downloadsActive: true), isNull);
    });
  });

  group('banner policy', () {
    test('waits for the initial delay, consent and foreground', () {
      final p = policy();
      expect(
        p.canRequestBanner(
          placement: AdPlacement.homeBanner,
          consentGranted: true,
          appInForeground: true,
          downloadsActive: false,
          now: sessionStart.add(const Duration(seconds: 19)),
        ),
        isFalse,
      );
      expect(
        p.canRequestBanner(
          placement: AdPlacement.homeBanner,
          consentGranted: false,
          appInForeground: true,
          downloadsActive: false,
          now: sessionStart.add(const Duration(seconds: 20)),
        ),
        isFalse,
      );
      expect(
        p.canRequestBanner(
          placement: AdPlacement.homeBanner,
          consentGranted: true,
          appInForeground: false,
          downloadsActive: false,
          now: sessionStart.add(const Duration(seconds: 20)),
        ),
        isFalse,
      );
      expect(
        p.canRequestBanner(
          placement: AdPlacement.homeBanner,
          consentGranted: true,
          appInForeground: true,
          downloadsActive: false,
          now: sessionStart.add(const Duration(seconds: 20)),
        ),
        isTrue,
      );
    });

    test('does not show the downloads banner during an active download', () {
      final p = policy();
      final now = sessionStart.add(const Duration(seconds: 30));
      expect(
        p.canRequestBanner(
          placement: AdPlacement.downloadsBanner,
          consentGranted: true,
          appInForeground: true,
          downloadsActive: true,
          now: now,
        ),
        isFalse,
      );
      expect(
        p.canRequestBanner(
          placement: AdPlacement.downloadsBanner,
          consentGranted: true,
          appInForeground: true,
          downloadsActive: false,
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('interstitial policy', () {
    test('requires grace, foreground, consent and a quiet app', () {
      final p = policy();
      final afterGrace = sessionStart.add(const Duration(seconds: 60));

      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: false,
          downloadsActive: false,
          isInPiP: false,
          isUserInputActive: false,
          now: sessionStart.add(const Duration(seconds: 59)),
        ),
        isFalse,
      );
      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: true,
          downloadsActive: false,
          isInPiP: false,
          isUserInputActive: false,
          now: afterGrace,
        ),
        isFalse,
      );
      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: false,
          downloadsActive: true,
          isInPiP: false,
          isUserInputActive: false,
          now: afterGrace,
        ),
        isFalse,
      );
      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: false,
          downloadsActive: false,
          isInPiP: true,
          isUserInputActive: false,
          now: afterGrace,
        ),
        isFalse,
      );
      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: false,
          downloadsActive: false,
          isInPiP: false,
          isUserInputActive: true,
          now: afterGrace,
        ),
        isFalse,
      );
      expect(
        p.canShowInterstitial(
          placement: AdPlacement.interstitialDefault,
          consentGranted: true,
          appInForeground: true,
          mediaActive: false,
          downloadsActive: false,
          isInPiP: false,
          isUserInputActive: false,
          now: afterGrace,
        ),
        isTrue,
      );
    });
  });
}
