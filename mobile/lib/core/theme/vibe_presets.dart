import 'package:flutter/material.dart';

/// Named dark themes (like the reference players: Dub classic gold,
/// midnight blue, emerald, rose...). Every surface derives from these so
/// the whole app repaints coherently when the user switches preset.
class VibePreset {
  final String id;
  final String labelKey;
  final Color accent;
  final Color background;
  final Color surface;
  final Color card;
  final Color border;

  const VibePreset({
    required this.id,
    required this.labelKey,
    required this.accent,
    required this.background,
    required this.surface,
    required this.card,
    required this.border,
  });

  static const List<VibePreset> presets = [
    VibePreset(
      id: 'classic',
      labelKey: 'themeClassic',
      accent: Color(0xFF6C63FF),
      background: Color(0xFF0F0F23),
      surface: Color(0xFF1A1A2E),
      card: Color(0xFF16213E),
      border: Color(0xFF2A2A4A),
    ),
    VibePreset(
      id: 'midnight',
      labelKey: 'themeMidnight',
      accent: Color(0xFF38BDF8),
      background: Color(0xFF050B1E),
      surface: Color(0xFF0A1530),
      card: Color(0xFF0E1C40),
      border: Color(0xFF1E3A6E),
    ),
    VibePreset(
      id: 'emerald',
      labelKey: 'themeEmerald',
      accent: Color(0xFF22C55E),
      background: Color(0xFF04120D),
      surface: Color(0xFF071E15),
      card: Color(0xFF0A2A1D),
      border: Color(0xFF14532D),
    ),
    VibePreset(
      id: 'rose',
      labelKey: 'themeRose',
      accent: Color(0xFFFF6584),
      background: Color(0xFF170812),
      surface: Color(0xFF241019),
      card: Color(0xFF2E1420),
      border: Color(0xFF5B2337),
    ),
    VibePreset(
      id: 'amber',
      labelKey: 'themeAmber',
      accent: Color(0xFFF5B301),
      background: Color(0xFF12100A),
      surface: Color(0xFF1D1910),
      card: Color(0xFF26200F),
      border: Color(0xFF4A3F1A),
    ),
    VibePreset(
      id: 'mono',
      labelKey: 'themeMono',
      accent: Color(0xFFE8E8E8),
      background: Color(0xFF000000),
      surface: Color(0xFF101010),
      card: Color(0xFF1A1A1A),
      border: Color(0xFF2E2E2E),
    ),
  ];

  static VibePreset byId(String id) {
    return presets.firstWhere((p) => p.id == id, orElse: () => presets.first);
  }
}
