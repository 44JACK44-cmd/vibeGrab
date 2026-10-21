import 'package:flutter/material.dart';

/// Visual skins for the player surfaces (full audio player and mini player).
///
/// The video surface keeps its own black, edge-to-edge layout on purpose:
/// a decorative background there would fight the video frame and the
/// controls. Everything else in the app (local library, Explorer audio,
/// downloads) uses the same style, so the choice is global.
enum PlayerStyle {
  /// The original look: flat background, square artwork, big cover.
  classic,

  /// Artwork fills the screen behind a blur + gradient scrim.
  immersive,

  /// No artwork block: a compact, list-like player.
  compact,
}

extension PlayerStyleInfo on PlayerStyle {
  /// Localization key of the style name.
  String get labelKey => switch (this) {
        PlayerStyle.classic => 'playerStyleClassic',
        PlayerStyle.immersive => 'playerStyleImmersive',
        PlayerStyle.compact => 'playerStyleCompact',
      };

  String get descriptionKey => switch (this) {
        PlayerStyle.classic => 'playerStyleClassicDesc',
        PlayerStyle.immersive => 'playerStyleImmersiveDesc',
        PlayerStyle.compact => 'playerStyleCompactDesc',
      };

  IconData get icon => switch (this) {
        PlayerStyle.classic => Icons.album_outlined,
        PlayerStyle.immersive => Icons.blur_on,
        PlayerStyle.compact => Icons.view_agenda_outlined,
      };

  static PlayerStyle? parse(String? raw) {
    if (raw == null) return null;
    for (final style in PlayerStyle.values) {
      if (style.name == raw) return style;
    }
    return null;
  }
}
