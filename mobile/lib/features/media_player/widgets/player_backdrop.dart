import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import '../../../core/theme/player_style.dart';

/// Paints the background of a player surface according to the global
/// [PlayerStyle].
///
/// The artwork is decorative only: it never covers the controls and it is
/// never used to decide what is playing.
class PlayerBackdrop extends StatelessWidget {
  final PlayerStyle style;
  final Widget child;

  /// Local artwork file (embedded cover or cached thumbnail).
  final String? artworkPath;

  /// Remote artwork URL.
  final String? artworkUrl;

  /// Rounds the artwork (mini player bar).
  final BorderRadius? borderRadius;

  const PlayerBackdrop({
    super.key,
    required this.style,
    required this.child,
    this.artworkPath,
    this.artworkUrl,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    switch (style) {
      case PlayerStyle.classic:
        return Container(color: cs.surface, child: child);
      case PlayerStyle.compact:
        return Container(color: cs.surface, child: child);
      case PlayerStyle.immersive:
        return Stack(
          fit: StackFit.expand,
          children: [
            _ArtworkLayer(
              path: artworkPath,
              url: artworkUrl,
              borderRadius: borderRadius,
            ),
            _ScrimLayer(cs: cs, borderRadius: borderRadius),
            child,
          ],
        );
    }
  }
}

class _ArtworkLayer extends StatelessWidget {
  final String? path;
  final String? url;
  final BorderRadius? borderRadius;

  const _ArtworkLayer({
    required this.path,
    required this.url,
    this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget? image;

    if (path != null && path!.isNotEmpty) {
      final file = File(path!);
      if (file.existsSync()) {
        image = Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
    }
    if (image == null && url != null && url!.isNotEmpty) {
      if (url!.startsWith('http')) {
        image = Image.network(
          url!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      } else {
        final file = File(url!);
        if (file.existsSync()) {
          image = Image.file(
            file,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          );
        }
      }
    }

    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        cs.primary.withValues(alpha: 0.55),
        cs.secondaryContainer.withValues(alpha: 0.45),
      ],
    );

    Widget base;
    if (image == null) {
      base = DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: const SizedBox.expand(),
      );
    } else {
      base = Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(gradient: gradient),
            child: const SizedBox.expand(),
          ),
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 42, sigmaY: 42),
            child: Opacity(opacity: 0.55, child: image),
          ),
        ],
      );
    }

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: base);
    }
    return base;
  }
}

class _ScrimLayer extends StatelessWidget {
  final ColorScheme cs;
  final BorderRadius? borderRadius;

  const _ScrimLayer({required this.cs, this.borderRadius});

  @override
  Widget build(BuildContext context) {
    final layer = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            cs.surface.withValues(alpha: 0.35),
            cs.surface.withValues(alpha: 0.82),
            cs.surface.withValues(alpha: 0.96),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: const SizedBox.expand(),
    );
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: layer);
    }
    return layer;
  }
}
