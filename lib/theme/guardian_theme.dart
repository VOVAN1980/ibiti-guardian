import 'package:flutter/material.dart';
import 'package:ibiti_guardian/theme/guardian_colors.dart';
import 'package:ibiti_guardian/theme/guardian_text_styles.dart';

class GuardianTheme {
  // Main Theme Definition
  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      primaryColor: GuardianColors.accent,
      scaffoldBackgroundColor: GuardianColors.background,

      // Color Scheme
      colorScheme: const ColorScheme.dark(
        primary: GuardianColors.accent,
        secondary: GuardianColors.secondary,
        surface: GuardianColors.surface,
        error: GuardianColors.danger,
        onSurface: GuardianColors.textPrimary,
        onPrimary: GuardianColors.textPrimary,
      ),

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GuardianTextStyles.headline,
        iconTheme: IconThemeData(color: GuardianColors.textPrimary),
      ),

      // Bottom Navigation
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: GuardianColors.surface,
        selectedItemColor: GuardianColors.accent,
        unselectedItemColor: GuardianColors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),

      // Cards
      cardTheme: CardThemeData(
        color: GuardianColors.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: GuardianColors.glassBorder, width: 1),
        ),
      ),

      // Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: GuardianColors.accent,
          foregroundColor: GuardianColors.textPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GuardianTextStyles.button,
        ),
      ),

      // Icons
      iconTheme: const IconThemeData(
        color: GuardianColors.textPrimary,
        size: 24,
      ),

      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: GuardianColors.surfaceElevated,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: GuardianColors.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              const BorderSide(color: GuardianColors.accent, width: 1.5),
        ),
        hintStyle: GuardianTextStyles.bodySecondary
            .copyWith(color: GuardianColors.textTertiary),
      ),

      // Fonts
      useMaterial3: true,
    );
  }
}
