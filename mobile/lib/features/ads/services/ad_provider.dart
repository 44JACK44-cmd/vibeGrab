import 'package:flutter/widgets.dart';

import '../models/ad_placement.dart';

/// A loaded banner that can be displayed without issuing another request.
///
/// The provider owns the platform object. The app only disposes it when the
/// banner is replaced, the session ends, or the provider is shut down.
class AdBannerHandle {
  AdBannerHandle({
    required this.view,
    required this.height,
    required this.dispose,
  });

  final Widget view;
  final double height;
  final VoidCallback dispose;
}

/// Network-agnostic advertising boundary.
///
/// VibeGrab currently ships an AdMob implementation, but the manager and policy
/// only depend on this contract. That keeps consent, frequency and fallback
/// behaviour independent from a specific SDK.
abstract class AdProvider {
  bool get isInitialized;

  Future<void> initialize();

  Future<AdBannerHandle?> loadBanner({
    required AdPlacement placement,
    required int width,
  });

  Future<bool> showInterstitial({required AdPlacement placement});

  Future<void> dispose();
}

/// Safe fallback used when no provider is configured.
class NoopAdProvider implements AdProvider {
  @override
  bool get isInitialized => false;

  @override
  Future<void> initialize() async {}

  @override
  Future<AdBannerHandle?> loadBanner({
    required AdPlacement placement,
    required int width,
  }) async {
    return null;
  }

  @override
  Future<bool> showInterstitial({required AdPlacement placement}) async {
    return false;
  }

  @override
  Future<void> dispose() async {}
}
