import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
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

  /// Stock light / dark themes. The reading palettes already encode the
  /// app's paper / night colors, so these delegate to [forReadingTheme]
  /// instead of building a second scheme by hand.
  static ThemeData light() => forReadingTheme(ReadingTheme.paper);

  static ThemeData dark() => forReadingTheme(ReadingTheme.night);

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
    // Overlay surfaces across the app use the panel radius and the panel fill
    // so menus / sheets / dialogs read as the same material as the library's
    // floating panels (see `core/widgets/app_overlay.dart`).
    final radius = BorderRadius.circular(Golden.radiusPanel);
    final overlay = scheme.surfaceContainerLow;

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
      // Popup menus (view mode, annotation actions): rounded panel, no hard
      // shadow ring, serif-free but roomy rows.
      popupMenuTheme: PopupMenuThemeData(
        color: overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
        textStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
        ),
      ),
      // Bottom sheets: transparent host so AppSheet paints its own rounded
      // panel (a coloured host would double the corner).
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalBackgroundColor: Colors.transparent,
        modalElevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Golden.radiusPanel),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: overlay,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
      // Snack bars: small floating pill, not a full-width bar, so they do not
      // cover the shelf or the reader chrome.
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          color: scheme.onInverseSurface,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Golden.radiusMedium),
        ),
        insetPadding: const EdgeInsets.symmetric(
          horizontal: Golden.s21,
          vertical: Golden.s13,
        ),
      ),
      // Dividers inside overlays match the panel hairline.
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: 0.6),
        thickness: 1,
        space: Golden.s21,
      ),
      // Tooltips follow the same radius family.
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(Golden.radiusSmall),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
      ),
      // Chips / segmented controls (filter bar, settings) use full pills.
      chipTheme: ChipThemeData(
        shape: const StadiumBorder(),
        side: BorderSide.none,
        backgroundColor: scheme.surfaceContainerHighest.withValues(
          alpha: 0.6,
        ),
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(color: scheme.onSurface, fontSize: 13),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.primary.withValues(alpha: 0.18),
        thumbColor: scheme.primary,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
    );
  }
}
