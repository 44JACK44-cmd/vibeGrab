import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../downloads/controllers/downloads_controller.dart';
import '../models/ad_placement.dart';
import 'vibegrab_ad_banner.dart';

/// Central host placed once in [MainShell].
///
/// Keeping one host avoids the duplicate/hidden requests that would happen if
/// every tab inside the IndexedStack mounted its own banner. Approved tabs get
/// a slot; analyser, settings and player routes do not.
class AppAdBannerHost extends StatelessWidget {
  const AppAdBannerHost({super.key, required this.tabIndex});

  final int tabIndex;

  @override
  Widget build(BuildContext context) {
    return Selector<DownloadsController, bool>(
      selector: (_, controller) =>
          controller.tasks.any((task) => task.isActive),
      builder: (context, downloadsActive, _) {
        final placement = AdPlacement.forTab(
          tabIndex,
          downloadsActive: downloadsActive,
        );
        return VibeGrabAdBanner(
          placement: placement,
          downloadsActive: downloadsActive,
        );
      },
    );
  }
}
