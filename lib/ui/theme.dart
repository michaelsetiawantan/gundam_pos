import 'package:flutter/material.dart';

/// Gundam POS CrustMeasure design tokens — petrol/teal connected-fieldwork look
/// consistent with design-v3. All interactive targets sized >= 44px.
class PosTheme {
  PosTheme._();

  // Petrol / teal palette.
  static const petrol = Color(0xFF004D4A); // deep petrol — surfaces, headers
  static const petrolDark = Color(0xFF003535);
  static const teal = Color(0xFF14B8A6); // connected accent — actions, active
  static const tealSoft = Color(0xFFB2F3EA); // soft teal — chips/selections
  static const mist = Color(0xFFF2F7F6); // near-white work surface
  static const ink = Color(0xFF1A2626); // primary text
  static const slate = Color(0xFF5B6B6A); // secondary text
  static const line = Color(0xFFDCE6E4); // hairlines
  static const danger = Color(0xFFC54343);
  static const warn = Color(0xFFB97E2A);
  static const ok = Color(0xFF2A8F6A);

  /// Minimum touch target per CrustMeasure (44 CSS px ≈ 44 logical px on a tab).
  static const minTouch = 44.0;

  static ThemeData theme() {
    final scheme = ColorScheme.fromSeed(
      seedColor: petrol,
      primary: petrol,
      secondary: teal,
      surface: mist,
    );
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: mist,
      fontFamily: 'Roboto',
    );
    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: petrol,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: teal,
          foregroundColor: ink,
          minimumSize: const Size(64, minTouch),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: teal,
          minimumSize: const Size(48, minTouch),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: petrol,
          side: const BorderSide(color: petrol, width: 1.5),
          minimumSize: const Size(64, minTouch),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: line),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: teal, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.white,
        side: const BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        labelStyle: const TextStyle(fontSize: 15, color: ink),
      ),
    );
  }
}