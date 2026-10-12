import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

/// Application theme definitions (FEATURES 8.2 / 8.11).
///
/// Material 3 light + dark schemes. The seed color is a calm reading-friendly
/// teal; both schemes are generated from it. The reader route additionally
/// overrides the scheme per reading theme via [forReadingTheme] -- canvas /
/// card / text colors then come from the active [ReadingPalette], which is
/// attached as a theme extension so widgets can reach the bitmap filters.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF2E6F6A);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );
    return _base(scheme).copyWith(extensions: const [ReadingPalette.paper]);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return _base(scheme).copyWith(extensions: const [ReadingPalette.night]);
  }

  /// Theme for the reader route under [theme] (FEATURES 8.11): scaffold
  /// background becomes the palette canvas, cards / placeholders take the
  /// palette surfaces, and the palette itself rides along as an extension.
  static ThemeData forReadingTheme(ReadingTheme theme) {
    final palette = readingPaletteFor(theme);
    final seeded = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: palette.brightness,
    );
    final scheme = seeded.copyWith(
      surface: palette.canvas,
      onSurface: palette.primaryText,
      surfaceContainerLow: palette.pageCard,
      surfaceContainerHighest: palette.placeholder,
    );
    return _base(scheme).copyWith(extensions: [palette]);
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
