import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/localization/app_localizations.dart';
import '../../../core/theme/app_animations.dart';
import '../models/ad_placement.dart';
import '../services/ad_manager.dart';
import '../services/ad_provider.dart';

/// The single reusable banner surface in the app shell.
///
/// The loaded [AdWidget] stays mounted while another tab is selected (Offstage)
/// so returning to an approved tab never creates a second impression request.
/// When no ad is available the surface collapses instead of leaving a fake
/// placeholder or an endless spinner.
class VibeGrabAdBanner extends StatefulWidget {
  const VibeGrabAdBanner({
    super.key,
    required this.placement,
    this.downloadsActive = false,
  });

  final AdPlacement? placement;
  final bool downloadsActive;

  @override
  State<VibeGrabAdBanner> createState() => _VibeGrabAdBannerState();
}

class _VibeGrabAdBannerState extends State<VibeGrabAdBanner> {
  AdPlacement? _lastPlacement;
  double? _lastWidth;
  bool? _lastReady;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AdManager>();
    final handle = manager.banner;

    return LayoutBuilder(
      builder: (context, constraints) {
        _syncRequest(context, constraints.maxWidth, manager.isReady);
        final blockedDownload =
            widget.downloadsActive &&
            widget.placement == AdPlacement.downloadsBanner;
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final visible =
            widget.placement != null &&
            handle != null &&
            !blockedDownload &&
            !keyboardOpen;

        return AnimatedSize(
          duration: AppDurations.fast,
          curve: AppCurves.easeOut,
          alignment: Alignment.topCenter,
          child: Offstage(
            offstage: !visible,
            child: handle == null
                ? const SizedBox.shrink()
                : _BannerSurface(handle: handle),
          ),
        );
      },
    );
  }

  void _syncRequest(BuildContext context, double width, bool ready) {
    if (width <= 0) return;
    final placement = widget.placement;
    final placementChanged = placement != _lastPlacement;
    final widthChanged =
        _lastWidth == null || (width - _lastWidth!).abs() >= 48;
    final readyChanged = ready != _lastReady;
    if (!placementChanged && !widthChanged && !readyChanged) return;

    _lastPlacement = placement;
    _lastWidth = width;
    _lastReady = ready;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final manager = context.read<AdManager>();
      if (placement == null) {
        manager.setVisiblePlacement(null);
        return;
      }
      manager.ensureBanner(
        placement: placement,
        width: width,
        downloadsActive: widget.downloadsActive,
      );
    });
  }
}

class _BannerSurface extends StatelessWidget {
  const _BannerSurface({required this.handle});

  final AdBannerHandle handle;

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;

    return Semantics(
      container: true,
      label: loc.adLabel,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          border: Border(
            top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.28)),
          ),
        ),
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  loc.adLabel.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    height: 1.2,
                    letterSpacing: 0.9,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: handle.height,
              child: Center(child: handle.view),
            ),
          ],
        ),
      ),
    );
  }
}
