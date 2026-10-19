import 'dart:io';

import 'package:flutter/material.dart';

import '../../../services/media_engine.dart';

/// Thumbnail/cover content shared by the mini player and the audio sheet.
///
/// The fallback icon stays visible while an image loads and the image fades in
/// on top, so rebuilding the widget (minimize, PiP exit, theme change) never
/// paints an empty grey rectangle before the artwork reappears.
///
/// The engine caches remote thumbnails on disk (`currentThumbnailPath`), which
/// is what makes the image appear in the same frame instead of after a network
/// round-trip.
Widget mediaArtwork(
  MediaEngine engine,
  ColorScheme cs, {
  required double iconSize,
}) {
  final path = engine.currentThumbnailPath;
  final url = engine.currentThumbnail;
  final icon = Icon(
    engine.isVideo ? Icons.videocam : Icons.music_note,
    size: iconSize,
    color: cs.onSurfaceVariant,
  );

  ImageProvider<Object>? provider;
  if (path != null && path.isNotEmpty && File(path).existsSync()) {
    provider = FileImage(File(path));
  } else if (url != null && url.isNotEmpty) {
    if (url.startsWith('http')) {
      provider = NetworkImage(url);
    } else {
      provider = FileImage(File(url));
    }
  }

  return Stack(
    fit: StackFit.expand,
    children: [
      Center(child: icon),
      if (provider != null)
        Image(
          image: provider,
          fit: BoxFit.cover,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded || frame != null) return child;
            // Still decoding: keep the icon instead of an empty grey area.
            return const SizedBox.shrink();
          },
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        ),
    ],
  );
}
