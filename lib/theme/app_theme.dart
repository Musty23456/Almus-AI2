import 'package:flutter/material.dart';

import '../models/robot_state.dart';

/// Brand colours used throughout ALMUS AI.
class AlmusColors {
  const AlmusColors._();

  static const Color background = Color(0xFF070B1A);
  static const Color surface = Color(0xFF0F1630);
  static const Color blue = Color(0xFF3D7BFF);
  static const Color cyan = Color(0xFF22E3F5);
  static const Color purple = Color(0xFF9B5CFF);
  static const Color mint = Color(0xFF3DF5B5);
  static const Color error = Color(0xFFFF5370);

  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[blue, purple],
  );

  static const LinearGradient titleGradient = LinearGradient(
    colors: <Color>[cyan, blue, purple],
  );

  /// Accent colour that represents a robot state.
  static Color forState(RobotState state) {
    return switch (state) {
      RobotState.idle => cyan,
      RobotState.listening => blue,
      RobotState.thinking => purple,
      RobotState.talking => mint,
      RobotState.error => error,
    };
  }
}

/// Material 3 themes (dark is the default, light is optional).
class AppTheme {
  const AppTheme._();

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final bool isDark = brightness == Brightness.dark;

    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: AlmusColors.blue,
      brightness: brightness,
    ).copyWith(
      primary: isDark ? AlmusColors.cyan : const Color(0xFF2559D9),
      secondary: AlmusColors.purple,
      tertiary: AlmusColors.cyan,
      surface: isDark ? AlmusColors.surface : Colors.white,
      onSurface: isDark ? const Color(0xFFEAF0FF) : const Color(0xFF111936),
      onSurfaceVariant:
          isDark ? const Color(0xFF9AA6C9) : const Color(0xFF55608A),
      outlineVariant:
          isDark ? const Color(0xFF263261) : const Color(0xFFD5DBF2),
      error: AlmusColors.error,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor:
            isDark ? const Color(0xF20B1230) : const Color(0xF2FFFFFF),
        indicatorColor: scheme.primary.withValues(alpha: 0.18),
        elevation: 0,
      ),
    );
  }
}
