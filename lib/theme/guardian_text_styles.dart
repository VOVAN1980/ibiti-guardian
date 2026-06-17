import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';

class GuardianTextStyles {
  // Ultra Big Titles (Expense feel)
  static const TextStyle display = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 42,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.0,
    height: 1.1,
  );

  static const TextStyle titleLarge = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.5,
    height: 1.2,
  );

  static const TextStyle titleMedium = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.3,
    height: 1.3,
  );

  // Headlines
  static const TextStyle headline = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 20,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
  );

  // Body
  static const TextStyle bodyPrimary = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    height: 1.5,
  );

  static const TextStyle bodySecondary = TextStyle(
    color: GuardianColors.textSecondary,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    height: 1.4,
  );

  // Small & Captions
  static const TextStyle caption = TextStyle(
    color: GuardianColors.textTertiary,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.2,
  );

  // Button Labels
  static const TextStyle button = TextStyle(
    color: GuardianColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.2,
  );

  // Mono (for addresses)
  static const TextStyle mono = TextStyle(
    color: GuardianColors.textSecondary,
    fontSize: 13,
    fontFamily:
        'RobotoMono', // Fallback, standard in many systems, or use standard mono if available
    letterSpacing: 0.1,
  );
}
