import 'dart:async';

import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/ad_config.dart';
import '../models/ad_placement.dart';
import 'ad_metrics.dart';
import 'ad_provider.dart';

/// Official Google Mobile Ads implementation for Android.
///
/// Debug builds use Google's test units. Release builds only reach this class
/// when [AdConfig.enabled] is true, which requires real IDs supplied at build
/// time. A failed load always resolves to `null` so the UI can collapse.
class AdMobProvider implements AdProvider {
  AdMobProvider({required AdMetrics metrics}) : _metrics = metrics;

  final AdMetrics _metrics;
  bool _initialized = false;

  @override
  bool get isInitialized => _initialized;

  @override
  Future<void> initialize() async {
    if (_initialized || !AdConfig.enabled) return;
    await MobileAds.instance.initialize();
    _initialized = true;
  }

  @override
  Future<AdBannerHandle?> loadBanner({
    required AdPlacement placement,
    required int width,
  }) async {
    if (!_initialized || !AdConfig.enabled) return null;

    _metrics.record(AdMetricEvent.request, placement);

    final safeWidth = width.clamp(200, 1200);
    AnchoredAdaptiveBannerAdSize? adaptiveSize;
    try {
      adaptiveSize = await AdSize.getLargeAnchoredAdaptiveBannerAdSize(
        safeWidth,
      );
    } catch (_) {
      adaptiveSize = null;
    }
    final size = adaptiveSize ?? AdSize.banner;

    final completer = Completer<AdBannerHandle?>();
    var settled = false;
    late final BannerAd banner;
    banner = BannerAd(
      adUnitId: AdConfig.bannerUnitId,
      size: size,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          _metrics.record(AdMetricEvent.loaded, placement);
          if (settled) {
            // The request timed out while the SDK was still working.
            ad.dispose();
            return;
          }
          settled = true;
          completer.complete(
            AdBannerHandle(
              view: AdWidget(ad: banner),
              height: size.height.toDouble(),
              dispose: () => banner.dispose(),
            ),
          );
        },
        onAdFailedToLoad: (ad, error) {
          _metrics.record(
            AdMetricEvent.failed,
            placement,
            errorCode: error.code,
          );
          if (!settled) {
            settled = true;
            completer.complete(null);
          }
          ad.dispose();
        },
        onAdImpression: (ad) {
          _metrics.record(AdMetricEvent.impression, placement);
        },
        onAdClicked: (ad) {
          _metrics.record(AdMetricEvent.clicked, placement);
        },
      ),
    );

    try {
      await banner.load();
    } catch (_) {
      if (!settled) {
        settled = true;
        completer.complete(null);
        banner.dispose();
      }
    }

    return completer.future.timeout(
      AdConfig.bannerRequestTimeout,
      onTimeout: () {
        if (!settled) {
          settled = true;
          banner.dispose();
        }
        return null;
      },
    );
  }

  @override
  Future<bool> showInterstitial({required AdPlacement placement}) async {
    if (!_initialized || !AdConfig.enabled) return false;
    if (!AdConfig.canShowInterstitials) return false;

    _metrics.record(AdMetricEvent.request, placement);

    final loadCompleter = Completer<InterstitialAd?>();
    var loadSettled = false;
    try {
      await InterstitialAd.load(
        adUnitId: AdConfig.interstitialUnitId,
        request: const AdRequest(),
        adLoadCallback: InterstitialAdLoadCallback(
          onAdLoaded: (ad) {
            _metrics.record(AdMetricEvent.loaded, placement);
            if (loadSettled) {
              ad.dispose();
              return;
            }
            loadSettled = true;
            loadCompleter.complete(ad);
          },
          onAdFailedToLoad: (error) {
            _metrics.record(
              AdMetricEvent.failed,
              placement,
              errorCode: error.code,
            );
            if (!loadSettled) {
              loadSettled = true;
              loadCompleter.complete(null);
            }
          },
        ),
      );
    } catch (_) {
      if (!loadSettled) {
        loadSettled = true;
        loadCompleter.complete(null);
      }
    }

    final ad = await loadCompleter.future.timeout(
      AdConfig.bannerRequestTimeout,
      onTimeout: () {
        loadSettled = true;
        return null;
      },
    );
    if (ad == null) return false;

    final shownCompleter = Completer<bool>();
    ad.fullScreenContentCallback = FullScreenContentCallback<InterstitialAd>(
      onAdShowedFullScreenContent: (ad) {
        _metrics.record(AdMetricEvent.interstitialShown, placement);
      },
      onAdImpression: (ad) {
        _metrics.record(AdMetricEvent.impression, placement);
      },
      onAdClicked: (ad) {
        _metrics.record(AdMetricEvent.clicked, placement);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        _metrics.record(AdMetricEvent.failed, placement, errorCode: error.code);
        ad.dispose();
        if (!shownCompleter.isCompleted) shownCompleter.complete(false);
      },
      onAdDismissedFullScreenContent: (ad) {
        _metrics.record(AdMetricEvent.dismissed, placement);
        ad.dispose();
        if (!shownCompleter.isCompleted) shownCompleter.complete(true);
      },
    );

    try {
      await ad.show();
    } catch (_) {
      ad.dispose();
      if (!shownCompleter.isCompleted) shownCompleter.complete(false);
    }
    return shownCompleter.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () => false,
    );
  }

  @override
  Future<void> dispose() async {
    _initialized = false;
  }
}
