/// Formats that the app can request from its ad provider.
enum AdFormat { banner, interstitial }

/// Every surface that is explicitly allowed to request advertising.
///
/// A placement is not a promise that an ad will be shown: [AdPolicy] and
/// [AdFrequencyController] still decide whether a request is safe. Keeping the
/// list small and explicit prevents ads from leaking into the player, the
/// analyser or the settings screen.
enum AdPlacement {
  homeBanner('home_banner', AdFormat.banner),
  browserBanner('browser_banner', AdFormat.banner),
  downloadsBanner('downloads_banner', AdFormat.banner),
  libraryBanner('library_banner', AdFormat.banner),
  interstitialDefault('interstitial_default', AdFormat.interstitial);

  const AdPlacement(this.id, this.format);

  final String id;
  final AdFormat format;

  static AdPlacement? forTab(int index, {required bool downloadsActive}) {
    switch (index) {
      case 0:
        return AdPlacement.homeBanner;
      case 1:
        return AdPlacement.browserBanner;
      case 3:
        return downloadsActive ? null : AdPlacement.downloadsBanner;
      case 4:
        return AdPlacement.libraryBanner;
      default:
        // Analyser (2), settings (5), player routes and any future tab without
        // an explicitly approved secondary slot stay ad-free.
        return null;
    }
  }
}
