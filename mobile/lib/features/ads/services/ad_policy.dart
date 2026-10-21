import '../config/ad_config.dart';
import '../models/ad_placement.dart';
import 'ad_frequency_controller.dart';

/// Central decision point for every ad request.
///
/// The widget layer must never decide by itself whether an ad is appropriate.
/// This class keeps the rules testable and makes it impossible for a new tab to
/// silently start showing interstitials.
class AdPolicy {
  AdPolicy({
    required this.frequency,
    required this.sessionStart,
    Duration? bannerInitialDelay,
    Duration? interstitialSessionGrace,
  }) : _bannerInitialDelay = bannerInitialDelay ?? AdConfig.initialBannerDelay,
       _interstitialSessionGrace =
           interstitialSessionGrace ?? AdConfig.interstitialSessionGrace;

  final AdFrequencyController frequency;
  final DateTime sessionStart;
  final Duration _bannerInitialDelay;
  final Duration _interstitialSessionGrace;

  Duration get bannerInitialDelay => _bannerInitialDelay;

  AdPlacement? placementForTab(int index, {required bool downloadsActive}) {
    return AdPlacement.forTab(index, downloadsActive: downloadsActive);
  }

  /// Banners are allowed only in an explicitly approved, non-critical slot.
  bool canRequestBanner({
    required AdPlacement placement,
    required bool consentGranted,
    required bool appInForeground,
    required bool downloadsActive,
    required DateTime now,
  }) {
    if (!consentGranted || !appInForeground) return false;
    if (placement.format != AdFormat.banner) return false;
    if (now.difference(sessionStart) < _bannerInitialDelay) return false;
    if (placement == AdPlacement.downloadsBanner && downloadsActive) {
      return false;
    }
    return true;
  }

  /// Interstitials are *capable* of being shown, but no automatic trigger is
  /// enabled in VibeGrab yet. This method is used by future, explicitly safe
  /// transitions and by tests; it does not schedule anything.
  bool canShowInterstitial({
    required AdPlacement placement,
    required bool consentGranted,
    required bool appInForeground,
    required bool mediaActive,
    required bool downloadsActive,
    required bool isInPiP,
    required bool isUserInputActive,
    required DateTime now,
  }) {
    if (!consentGranted || !appInForeground) return false;
    if (placement.format != AdFormat.interstitial) return false;

    // Never interrupt media, downloads, PiP, playback controls or typing.
    if (mediaActive || downloadsActive || isInPiP || isUserInputActive) {
      return false;
    }

    return frequency.canShowInterstitial(
      now: now,
      sessionGrace: _interstitialSessionGrace,
    );
  }
}
