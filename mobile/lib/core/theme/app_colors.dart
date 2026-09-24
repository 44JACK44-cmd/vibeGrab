import 'package:flutter/material.dart';

class VibeAccent {
  final String name;
  final Color color;

  const VibeAccent({required this.name, required this.color});

  String get label => name;

  static const List<VibeAccent> accents = [
    VibeAccent(name: 'Purple', color: Color(0xFF6C63FF)),
    VibeAccent(name: 'Cyan', color: Color(0xFF00B4D8)),
    VibeAccent(name: 'Green', color: Color(0xFF06D6A0)),
    VibeAccent(name: 'Red', color: Color(0xFFFF6B6B)),
    VibeAccent(name: 'Amber', color: Color(0xFFFFB74D)),
    VibeAccent(name: 'Pink', color: Color(0xFFEC407A)),
    VibeAccent(name: 'Deep Purple', color: Color(0xFF7C4DFF)),
  ];
}

class AppColors {
  AppColors._();

  static const Color _defaultAccent = Color(0xFF6C63FF);

  static const Color background = Color(0xFF0F0F23);
  static const Color surface = Color(0xFF1A1A2E);
  static const Color surfaceElevated = Color(0xFF222244);
  static const Color card = Color(0xFF16213E);
  static const Color border = Color(0xFF2A2A4A);

  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textMuted = Color(0xFF6E6E8A);

  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFEF5350);
  static const Color warning = Color(0xFFFFB74D);

  static Color accent([Color? custom]) => custom ?? _defaultAccent;

  static Color onAccent([Color? custom]) {
    final c = custom ?? _defaultAccent;
    return ThemeData.estimateBrightnessForColor(c) == Brightness.dark
        ? Colors.white
        : Colors.black;
  }

  static Color accentShade(Color base, double factor) {
    return Color.lerp(base, Colors.black, factor)!;
  }

  static Color accentTint(Color base, double factor) {
    return Color.lerp(base, Colors.white, factor)!;
  }
}

class AppColorsLight {
  AppColorsLight._();

  static const Color background = Color(0xFFF5F5FA);
  static const Color surface = Colors.white;
  static const Color surfaceElevated = Color(0xFFF0F0F8);
  static const Color card = Colors.white;
  static const Color border = Color(0xFFE0E0E8);

  static const Color textPrimary = Color(0xFF1A1A2E);
  static const Color textSecondary = Color(0xFF6E6E8A);
  static const Color textMuted = Color(0xFFB0B0C0);

  static const Color success = Color(0xFF388E3C);
  static const Color error = Color(0xFFD32F2F);
  static const Color warning = Color(0xFFF57C00);
}
