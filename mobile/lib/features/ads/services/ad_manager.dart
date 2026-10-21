import 'dart:async';

import 'package:flutter/material.dart';

import '../config/ad_config.dart';
import '../models/ad_placement.dart';
import 'ad_consent_manager.dart';
import 'ad_frequency_controller.dart';
import 'ad_metrics.dart';
import 'ad_policy.dart';
import 'ad_provider.dart';
import 'admob_provider.dart';

/// Application-wide coordinator for advertising.
///
/// There is one instance for the whole shell. It owns consent, the provider,
/// the shared frequency limiter, the loaded banner and retry backoff. Screens
/// must not create their own SDK objects or timers.
class AdManager extends ChangeNotifier with WidgetsBindingObserver {
  AdManager({
    AdProvider? provider,
    AdConsentManager? consent,
    AdMetrics? metrics,
    AdFrequencyController? frequency,
    AdPolicy? policy,
    DateTime Function()? clock,
    bool addLifecycleObserver = true,
  }) : _clock = clock ?? DateTime.now,
       _metrics = metrics ?? AdMetrics(),
       _consent = consent ?? AdConsentManager(),
       _addLifecycleObserver = addLifecycleObserver {
    _sessionStart = _clock();
    _provider = provider ?? AdMobProvider(metrics: _metrics);
    _frequency =
        frequency ?? AdFrequencyController(sessionStart: _sessionStart);
    _policy =
        policy ?? AdPolicy(frequency: _frequency, sessionStart: _sessionStart);
  }

  final DateTime Function() _clock;
  final AdMetrics _metrics;
  final AdConsentManager _consent;
  final bool _addLifecycleObserver;

  late final DateTime _sessionStart;
  late final AdProvider _provider;
  late final AdFrequencyController _frequency;
  late final AdPolicy _policy;

  bool _initialized = false;
  bool _initializing = false;
  bool _disposed = false;
  bool _observerAdded = false;
  bool _ready = false;
  bool _consentGranted = false;
  bool _appInForeground = true;

  AdBannerHandle? _banner;
  bool _bannerLoading = false;
  double? _bannerWidth;
  AdPlacement? _lastPlacement;
  bool _lastDownloadsActive = false;
  int _bannerFailures = 0;
  DateTime? _bannerRetryAt;
  Timer? _retryTimer;
  Timer? _bannerStartTimer;
  String? _lastError;

  AdBannerHandle? get banner => _banner;
  bool get bannerLoading => _bannerLoading;
  bool get isReady => _ready;
  bool get isInitialized => _initialized;
  bool get canRequestAds => _consentGranted;
  bool get privacyOptionsRequired => _consent.privacyOptionsRequired;
  String? get lastError => _lastError;
  AdMetrics get metrics => _metrics;

  Future<void> initialize() async {
    if (_initialized || _initializing || _disposed) return;
    if (!AdConfig.enabled) {
      _lastError = 'ads_disabled';
      return;
    }

    _initializing = true;
    if (_addLifecycleObserver) {
      WidgetsBinding.instance.addObserver(this);
      _observerAdded = true;
    }

    await _frequency.init();
    final granted = await _consent.requestConsent();
    _consentGranted = granted;

    if (!granted) {
      _lastError = 'consent_not_available';
      _initialized = true;
      _initializing = false;
      _notify();
      return;
    }

    try {
      await _provider.initialize();
      _ready = true;
      _lastError = null;
    } catch (error) {
      // Ads are optional. A provider/SDK failure must leave the rest of the
      // app untouched.
      _lastError = 'provider_init_failed';
    }

    _initialized = true;
    _initializing = false;
    _notify();
    if (_ready) _scheduleBannerStartAfterReadiness();
  }

  /// Tells the manager whether an approved slot is currently visible. When no
  /// slot is visible, retries stop so hidden tabs never request ads.
  void setVisiblePlacement(AdPlacement? placement) {
    _lastPlacement = placement;
    if (placement == null) {
      _retryTimer?.cancel();
      _bannerStartTimer?.cancel();
    }
  }

  void _scheduleBannerStartAfterReadiness() {
    final placement = _lastPlacement;
    final width = _bannerWidth;
    if (placement == null ||
        width == null ||
        _banner != null ||
        _bannerLoading) {
      return;
    }
    final elapsed = _clock().difference(_sessionStart);
    final remaining = _policy.bannerInitialDelay - elapsed;
    if (remaining > Duration.zero) {
      _scheduleBannerStart(remaining);
    } else {
      ensureBanner(
        placement: placement,
        width: width,
        downloadsActive: _lastDownloadsActive,
      );
    }
  }

  void _scheduleBannerStart(Duration delay) {
    _bannerStartTimer?.cancel();
    _bannerStartTimer = Timer(delay, () {
      _bannerStartTimer = null;
      final placement = _lastPlacement;
      final width = _bannerWidth;
      if (placement != null && width != null) {
        ensureBanner(
          placement: placement,
          width: width,
          downloadsActive: _lastDownloadsActive,
        );
      }
    });
  }

  /// Requests the single shared banner once and reuses it across approved tabs.
  /// A rebuild, tab change or normal navigation never issues another request.
  Future<void> ensureBanner({
    required AdPlacement placement,
    required double width,
    bool downloadsActive = false,
  }) async {
    if (_disposed || width <= 0) return;
    _lastPlacement = placement;
    _lastDownloadsActive = downloadsActive;
    _bannerWidth = width;

    if (!_ready || !_consentGranted) return;
    final now = _clock();

    // The first moments after launch stay ad-free. Schedule the request for the
    // end of that grace period; otherwise no rebuild would ever trigger it.
    final elapsed = now.difference(_sessionStart);
    if (elapsed < _policy.bannerInitialDelay) {
      if (_appInForeground &&
          !(placement == AdPlacement.downloadsBanner && downloadsActive)) {
        _scheduleBannerStart(_policy.bannerInitialDelay - elapsed);
      }
      return;
    }

    if (!_policy.canRequestBanner(
      placement: placement,
      consentGranted: _consentGranted,
      appInForeground: _appInForeground,
      downloadsActive: downloadsActive,
      now: now,
    )) {
      return;
    }
    if (_bannerLoading || _banner != null) return;
    final retryAt = _bannerRetryAt;
    if (retryAt != null && now.isBefore(retryAt)) {
      // A previous failure was waiting when the slot became hidden or the app
      // went to the background. Re-arm the timer instead of losing the retry.
      _armRetryTimer();
      return;
    }

    _bannerLoading = true;
    _bannerStartTimer?.cancel();
    _notify();

    AdBannerHandle? handle;
    try {
      handle = await _provider.loadBanner(
        placement: placement,
        width: width.round(),
      );
    } catch (_) {
      handle = null;
    }
    if (_disposed) {
      handle?.dispose();
      return;
    }
    if (!_consentGranted) {
      // Consent may have been revoked while the request was in flight.
      handle?.dispose();
      _bannerLoading = false;
      _notify();
      return;
    }

    _bannerLoading = false;
    if (handle != null) {
      _banner = handle;
      _bannerFailures = 0;
      _bannerRetryAt = null;
      _retryTimer?.cancel();
      _bannerStartTimer?.cancel();
    } else {
      _bannerFailures += 1;
      _scheduleRetry();
    }
    _notify();
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _bannerStartTimer?.cancel();
    final exponent = (_bannerFailures - 1).clamp(0, 5);
    final seconds = 30 * (1 << exponent);
    _bannerRetryAt = _clock().add(Duration(seconds: seconds));
    _armRetryTimer();
  }

  void _armRetryTimer() {
    _retryTimer?.cancel();
    final retryAt = _bannerRetryAt;
    if (retryAt == null) return;
    final delay = retryAt.difference(_clock());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _retryTimer = null;
      final placement = _lastPlacement;
      final width = _bannerWidth;
      if (placement != null && width != null) {
        ensureBanner(
          placement: placement,
          width: width,
          downloadsActive: _lastDownloadsActive,
        );
      }
    });
  }

  /// Capability for a future explicitly safe transition. VibeGrab does not
  /// schedule interstitials automatically; callers must pass the real app
  /// state and the policy still has the final word.
  Future<bool> showInterstitial({
    required AdPlacement placement,
    required bool mediaActive,
    required bool downloadsActive,
    required bool isInPiP,
    required bool isUserInputActive,
  }) async {
    if (!_ready || _disposed) return false;
    final now = _clock();
    if (!_policy.canShowInterstitial(
      placement: placement,
      consentGranted: _consentGranted,
      appInForeground: _appInForeground,
      mediaActive: mediaActive,
      downloadsActive: downloadsActive,
      isInPiP: isInPiP,
      isUserInputActive: isUserInputActive,
      now: now,
    )) {
      return false;
    }

    var shown = false;
    try {
      shown = await _provider.showInterstitial(placement: placement);
    } catch (_) {
      shown = false;
    }
    if (shown) {
      await _frequency.noteInterstitialShown(now);
    }
    return shown;
  }

  Future<bool> showPrivacyOptions() async {
    final shown = await _consent.showPrivacyOptions();
    if (shown) {
      _consentGranted = _consent.canRequestAds;
      if (!_consentGranted) {
        // The user revoked consent: drop the loaded banner immediately and
        // stop any scheduled request.
        _banner?.dispose();
        _banner = null;
        _bannerLoading = false;
        _bannerFailures = 0;
        _bannerRetryAt = null;
        _retryTimer?.cancel();
        _bannerStartTimer?.cancel();
      } else if (!_ready) {
        // Consent may have been denied on first launch and later granted from
        // the privacy options form.
        try {
          await _provider.initialize();
          _ready = true;
          _lastError = null;
        } catch (_) {
          _lastError = 'provider_init_failed';
        }
      }
      _notify();
      if (_ready) _scheduleBannerStartAfterReadiness();
    }
    return shown;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    if (!_appInForeground) {
      _retryTimer?.cancel();
      _bannerStartTimer?.cancel();
    } else {
      final placement = _lastPlacement;
      final width = _bannerWidth;
      if (placement != null &&
          width != null &&
          _banner == null &&
          !_bannerLoading) {
        ensureBanner(
          placement: placement,
          width: width,
          downloadsActive: _lastDownloadsActive,
        );
      }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    _bannerStartTimer?.cancel();
    if (_observerAdded) {
      WidgetsBinding.instance.removeObserver(this);
      _observerAdded = false;
    }
    _banner?.dispose();
    _banner = null;
    _provider.dispose();
    super.dispose();
  }
}
