import 'package:flutter/material.dart';

/// Application theme definitions (FEATURES 8.2).
///
/// Material 3 light + dark schemes. The seed color is a calm reading-friendly
/// teal; both schemes are generated from it. Milestone M1 only needs the
/// schemes themselves; persistence is handled by [ThemeController].
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF2E6F6A);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );
    return _base(scheme);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return _base(scheme);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: true,
      ),
    );
  }
}
