import 'package:flutter/material.dart';

class GuardianColors {
  // Base Premium Darks
  static const Color background = Color(0xFF000000); // Pure deep background
  static const Color surface = Color(0xFF0D1117); // Surface Layer
  static const Color surfaceElevated = Color(0xFF161B22); // Extra depth

  // Accents & Glows
  static const Color accent = Color(0xFF007AFF); // Clean Blue
  static const Color accentGlow = Color(0x66007AFF); // Soft glow
  static const Color secondary = Color(0xFF5856D6); // Deep Purple

  // Semantic Status
  static const Color success = Color(0xFF34C759);
  static const Color warning = Color(0xFFFF9500);
  static const Color danger = Color(0xFFFF3B30);
  static const Color info = Color(0xFF007AFF);

  // Text & Content - HIGH CONTRAST (Sunlight safe)
  static const Color textPrimary = Color(0xFFFFFFFF); // 100% White
  static const Color textSecondary = Color(0xD9FFFFFF); // 85% White
  static const Color textTertiary = Color(0x99FFFFFF); // 60% White (was 40%)

  // Glassmorphism elements
  static const Color glassBorder = Color(0x33FFFFFF); // 20% White (was 10%)
  static const Color glassBackground = Color(0x1AFFFFFF); // 10% White (was 5%)

  // Aliases for screen compatibility
  static const Color primary = accent; // Maps to accent blue
  static const Color border = glassBorder; // Maps to glass border
  static const Color navBg = surface; // Maps to surface dark
}
