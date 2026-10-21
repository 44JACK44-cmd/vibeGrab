import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibegrab/features/ads/models/ad_placement.dart';
import 'package:vibegrab/features/ads/services/ad_consent_manager.dart';
import 'package:vibegrab/features/ads/services/ad_frequency_controller.dart';
import 'package:vibegrab/features/ads/services/ad_manager.dart';
import 'package:vibegrab/features/ads/services/ad_metrics.dart';
import 'package:vibegrab/features/ads/services/ad_policy.dart';
import 'package:vibegrab/features/ads/services/ad_provider.dart';

class _FakeConsent extends AdConsentManager {
  _FakeConsent(this.granted);

  bool granted;
  bool revokeOnPrivacy = false;

  @override
  bool get canRequestAds => granted;

  @override
  Future<bool> requestConsent() async => granted;

  @override
  Future<bool> showPrivacyOptions() async {
    if (revokeOnPrivacy) granted = false;
    return true;
  }
}

class _FakeProvider implements AdProvider {
  int bannerLoads = 0;
  int interstitialShows = 0;
  bool initialized = false;

  @override
  bool get isInitialized => initialized;

  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<AdBannerHandle?> loadBanner({
    required AdPlacement placement,
    required int width,
  }) async {
    bannerLoads += 1;
    return AdBannerHandle(
      view: const SizedBox.shrink(),
      height: 50,
      dispose: () {},
    );
  }

  @override
  Future<bool> showInterstitial({required AdPlacement placement}) async {
    interstitialShows += 1;
    return true;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late DateTime now;
  late _FakeProvider provider;
  late AdFrequencyController frequency;
  late AdManager manager;

  setUp(() {
    now = DateTime(2026, 1, 1, 12);
    provider = _FakeProvider();
    frequency = AdFrequencyController(
      sessionStart: now,
      store: MemoryAdFrequencyStore(),
    );
    manager = AdManager(
      provider: provider,
      consent: _FakeConsent(true),
      metrics: AdMetrics(logEvents: false, clock: () => now),
      frequency: frequency,
      clock: () => now,
      addLifecycleObserver: false,
    );
  });

  tearDown(() {
    manager.dispose();
  });

  test('initialises the provider only after consent', () async {
    await manager.initialize();
    expect(provider.initialized, isTrue);
    expect(manager.isReady, isTrue);
  });

  test('does not request the banner during the startup grace period', () async {
    await manager.initialize();

    await manager.ensureBanner(placement: AdPlacement.homeBanner, width: 360);
    expect(provider.bannerLoads, 0);

    now = now.add(const Duration(seconds: 20));
    await manager.ensureBanner(placement: AdPlacement.homeBanner, width: 360);
    expect(provider.bannerLoads, 1);
  });

  test('reuses a loaded banner across rebuilds and tabs', () async {
    await manager.initialize();
    now = now.add(const Duration(seconds: 20));

    await manager.ensureBanner(placement: AdPlacement.homeBanner, width: 360);
    await manager.ensureBanner(
      placement: AdPlacement.libraryBanner,
      width: 360,
    );
    await manager.ensureBanner(
      placement: AdPlacement.browserBanner,
      width: 360,
    );

    expect(provider.bannerLoads, 1);
  });

  test('never loads the downloads banner during an active download', () async {
    await manager.initialize();
    now = now.add(const Duration(seconds: 20));

    await manager.ensureBanner(
      placement: AdPlacement.downloadsBanner,
      width: 360,
      downloadsActive: true,
    );
    expect(provider.bannerLoads, 0);

    await manager.ensureBanner(
      placement: AdPlacement.downloadsBanner,
      width: 360,
      downloadsActive: false,
    );
    expect(provider.bannerLoads, 1);
  });

  test(
    'interstitials stay blocked during media and respect cooldown',
    () async {
      await manager.initialize();
      now = now.add(const Duration(seconds: 60));

      final duringMedia = await manager.showInterstitial(
        placement: AdPlacement.interstitialDefault,
        mediaActive: true,
        downloadsActive: false,
        isInPiP: false,
        isUserInputActive: false,
      );
      expect(duringMedia, isFalse);
      expect(provider.interstitialShows, 0);

      final first = await manager.showInterstitial(
        placement: AdPlacement.interstitialDefault,
        mediaActive: false,
        downloadsActive: false,
        isInPiP: false,
        isUserInputActive: false,
      );
      expect(first, isTrue);
      expect(provider.interstitialShows, 1);

      final second = await manager.showInterstitial(
        placement: AdPlacement.interstitialDefault,
        mediaActive: false,
        downloadsActive: false,
        isInPiP: false,
        isUserInputActive: false,
      );
      expect(second, isFalse);
      expect(provider.interstitialShows, 1);
    },
  );

  test(
    'retries a pre-initialization request after readiness and grace',
    () async {
      manager.dispose();
      manager = AdManager(
        provider: provider,
        consent: _FakeConsent(true),
        metrics: AdMetrics(logEvents: false),
        frequency: frequency,
        policy: AdPolicy(
          frequency: frequency,
          sessionStart: now,
          bannerInitialDelay: const Duration(milliseconds: 10),
        ),
        clock: () => now,
        addLifecycleObserver: false,
      );

      await manager.ensureBanner(placement: AdPlacement.homeBanner, width: 360);
      expect(provider.bannerLoads, 0);

      await manager.initialize();
      now = now.add(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(provider.bannerLoads, 1);
    },
  );

  test('revoking consent from privacy options removes the banner', () async {
    final consent = _FakeConsent(true)..revokeOnPrivacy = true;
    manager.dispose();
    manager = AdManager(
      provider: provider,
      consent: consent,
      metrics: AdMetrics(logEvents: false),
      frequency: frequency,
      clock: () => now,
      addLifecycleObserver: false,
    );

    await manager.initialize();
    now = now.add(const Duration(seconds: 20));
    await manager.ensureBanner(placement: AdPlacement.homeBanner, width: 360);
    expect(manager.banner, isNotNull);

    expect(await manager.showPrivacyOptions(), isTrue);
    expect(manager.canRequestAds, isFalse);
    expect(manager.banner, isNull);
  });

  test('denied consent leaves ads disabled but the manager usable', () async {
    manager.dispose();
    manager = AdManager(
      provider: provider,
      consent: _FakeConsent(false),
      metrics: AdMetrics(logEvents: false),
      frequency: frequency,
      clock: () => now,
      addLifecycleObserver: false,
    );

    await manager.initialize();
    expect(manager.isReady, isFalse);
    expect(manager.canRequestAds, isFalse);
  });
}
