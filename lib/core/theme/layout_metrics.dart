/// Golden-ratio layout metrics.
///
/// Why a token file instead of scattered numbers: the library used to carry
/// arbitrary values (220px rail, 180px cards, 12px gaps, 3:4.4 covers) that
/// were each reasonable but did not relate to one another. Proportions that
/// share one ratio read as "designed" even when nobody can name the ratio.
///
/// Two different ratios are used, each where it is actually correct:
///
///  * **√2 (1.414…)** for the *object* -- a book cover is a sheet of A-series
///    paper folded in half (A5 = 148×210mm, 32开 = 130×184mm, both ≈1:1.42),
///    so its proportion is √2 rather than φ. Using φ made the covers ~9%
///    taller than any real book, which is why they read as "posters".
///  * **φ (1.618…)** for the *layout* -- the navigation rail is a φ⁴
///    subdivision of the window, and the header is a φ multiple of the icon
///    row.
///  * **Fibonacci spacing** (8, 13, 21, 34, 55, 89) for *rhythm* -- each step
///    is ≈ φ× the previous, so gaps feel consistently related instead of
///    being independent pixel choices.
///
/// The grid keeps one card size (~184dp) at every window width by solving the
/// column count from the available width, so widening the window adds columns
/// instead of inflating cards. That is what makes the shelf read as a shelf.
library;

import 'package:flutter/material.dart'
    show Brightness, BoxShadow, Colors, Offset, ThemeData;

/// Golden-ratio layout constants and helpers.
abstract final class Golden {
  /// The golden ratio.
  static const double phi = 1.6180339887498949;

  /// φ² ≈ 2.618.
  static const double phi2 = 2.6180339887498949;

  /// φ⁴ ≈ 6.854 -- used to derive the rail from the window width.
  static const double phi4 = 6.854101966249685;

  // ---------------------------------------------------------------------
  // Spacing scale.
  //
  // s4 is the 4dp device-grid unit (hairlines, insets); from s8 up the steps
  // are genuine Fibonacci numbers, so each is ≈ φ× the previous and the
  // rhythm holds. Do not insert arbitrary values between them -- 5, 13, 21,
  // 34... is what makes the gaps feel related rather than hand-picked.
  // ---------------------------------------------------------------------

  /// 4dp device-grid unit (not part of the φ ladder).
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s13 = 13;
  static const double s21 = 21;
  static const double s34 = 34;
  static const double s55 = 55;
  static const double s89 = 89;

  // ---------------------------------------------------------------------
  // Proportions
  // ---------------------------------------------------------------------

  /// Square root of two -- the proportion of A-series paper and therefore of
  /// almost every printed book (A5 148×210, 32开 130×184, B5 176×250; all
  /// within 1% of 1:1.414). Fold a sheet in half and it keeps this ratio,
  /// which is exactly how book pages come to have it.
  static const double sqrt2 = 1.4142135623730951;

  /// Cover width / height ≈ 0.707 (a portrait √2 rectangle).
  static const double coverRatio = 1 / sqrt2;

  /// Default font sizes used by the shelf's text block. They mirror Material
  /// 3's `bodyMedium` / `labelSmall`; the block is sized from these so every
  /// cover keeps the same height no matter how long a title is.
  static const double titleFontSize = 14;
  static const double metaFontSize = 11;

  /// Height of the title (two lines) + meta line block under a cover.
  ///
  /// Fixed on purpose: with a flexible block, a one-line title left the cover
  /// ~18dp taller than a two-line title in the same row, so covers looked
  /// different sizes. [textScale] keeps this honest under accessibility font
  /// scaling (the grid passes the same value, so the cell always matches).
  ///
  /// [slack] absorbs the font's ascent/descent overshoot: `height: 1.25`
  /// multiplies the font size but the rendered line box still includes
  /// leading that can push the last line a fraction past the computed box
  /// (observed as a 0.98px overflow on a tablet at 1.0 text scale).
  static double textBlockHeight({double textScale = 1.0, double slack = 2.0}) =>
      9 +
      titleLineHeight(null, textScale) * 2 +
      3 +
      metaFontSize * 1.2 * textScale +
      slack;

  /// Height of ONE title line at 1.25 leading.
  static double titleLineHeight(ThemeData? theme, double textScale) {
    final size = theme?.textTheme.bodyMedium?.fontSize ?? titleFontSize;
    return size * 1.25 * textScale;
  }

  /// Page header height: 64 = 40 × φ.
  static const double headerHeight = 64;

  /// Corner radii on the phi ladder: 8 / 13 / 18.
  ///
  /// [radiusPanel] is the floating-panel / overlay radius: dialogs, bottom
  /// sheets and menus all use it so popups read as the same material as the
  /// library's two panels.
  static const double radiusSmall = 8;
  static const double radiusMedium = 13;
  static const double radiusPanel = 18;

  /// Soft shadow shared by every raised surface (panels, dialogs, sheets).
  static List<BoxShadow> panelShadow(Brightness brightness) => [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: brightness == Brightness.dark ? 0.42 : 0.14,
          ),
          blurRadius: 22,
          offset: const Offset(0, 6),
        ),
      ];

  /// Default nav rail width: 128 × φ ≈ 207, rounded to 208.
  static const double railDefaultWidth = 208;

  /// Ideal card width: 114 × φ ≈ 184. Chosen so a card reads like a small
  /// hardback on a tablet rather than a thumbnail.
  static const double cardTargetWidth = 184;

  /// Card width bounds. Rounding the column count alone can land on a card
  /// ~30% off target (e.g. 500dp available -> 2 x 240dp); these bounds close
  /// the loop so a shelf never shows billboard-sized covers or postage
  /// stamps. ±17% around the target.
  static const double minCardWidth = 152;
  static const double maxCardWidth = 216;

  /// Rail width for a given window: one φ⁴ subdivision of the width, held
  /// inside [208, 264] so it stays a nav rail rather than a panel.
  static double railWidthFor(double viewportWidth) {
    if (viewportWidth <= 0) return railDefaultWidth;
    return (viewportWidth / phi4).clamp(railDefaultWidth, 264.0);
  }

  /// Grid columns and exact card width for [availableWidth] (already minus
  /// page padding).
  ///
  /// The column count is solved from [cardTargetWidth] rather than using a
  /// max-extent delegate, which leaves a ragged last column. Because the
  /// count is rounded, the card width drifts a little around the target
  /// (roughly 150-180dp) instead of growing without bound on wide screens.
  static ({int columns, double cardWidth}) gridFor(double availableWidth) {
    if (availableWidth <= 0) {
      return (columns: 1, cardWidth: cardTargetWidth);
    }
    final raw = (availableWidth + s21) / (cardTargetWidth + s21);
    // At least one column; 16 columns is a practical ceiling for a library.
    var columns = raw.round().clamp(1, 16);
    double widthFor(int n) => (availableWidth - s21 * (n - 1)) / n;

    // Close the loop on the resulting card size: rounding the count can land
    // well outside the target (500dp -> 2 x 240dp), so add columns while the
    // cards are too wide and drop them while the cards are too narrow.
    var cardWidth = widthFor(columns);
    while (cardWidth > maxCardWidth && columns < 16) {
      columns++;
      cardWidth = widthFor(columns);
    }
    while (cardWidth < minCardWidth && columns > 1) {
      columns--;
      cardWidth = widthFor(columns);
    }
    return (columns: columns, cardWidth: cardWidth);
  }

  /// Total cell height for a card of [cardWidth]: cover + text block.
  static double cellHeightFor(double cardWidth, {double textScale = 1.0}) =>
      cardWidth / coverRatio + textBlockHeight(textScale: textScale);

  /// Horizontal page padding: generous on desktop, tighter on phones.
  static double pagePaddingFor(double width) =>
      width < 700 ? s13 : s34;
}
