import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';

void main() {
  group('resolveReadingTheme', () {
    test('auto + light mode -> paper', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.light, Brightness.light),
        ReadingTheme.paper,
      );
    });
    test('auto + dark mode -> night', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.dark, Brightness.light),
        ReadingTheme.night,
      );
    });
    test('auto + system follows platform brightness', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.system, Brightness.dark),
        ReadingTheme.night,
      );
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.system, Brightness.light),
        ReadingTheme.paper,
      );
    });
    test('explicit choice always wins', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.parchment, ThemeMode.dark, Brightness.dark),
        ReadingTheme.parchment,
      );
      expect(
        resolveReadingTheme(
            ReadingTheme.night, ThemeMode.light, Brightness.light),
        ReadingTheme.night,
      );
    });
  });

  group('parseReadingTheme', () {
    test('round-trips every value and rejects garbage', () {
      for (final t in ReadingTheme.values) {
        expect(parseReadingTheme(t.name), t);
      }
      expect(parseReadingTheme('sepia'), isNull);
    });
  });

  group('night matrix', () {
    // Apply one matrix row to an rgb triple (ColorFilter.matrix semantics:
    // out = sum(k_i * c_i) + offset, channels 0..255, clamped).
    double applyRow(List<double> m, int row, double r, double g, double b) {
      final i = row * 5;
      return (m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 4])
          .clamp(0.0, 255.0);
    }

    List<double> apply(List<double> m, double r, double g, double b) => [
        applyRow(m, 0, r, g, b),
        applyRow(m, 1, r, g, b),
        applyRow(m, 2, r, g, b)];

    test('white page lands on #1F2022', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 255, 255, 255);
      expect(out[0], closeTo(31, 3));
      expect(out[1], closeTo(32, 3));
      expect(out[2], closeTo(34, 3));
    });
    test('black ink lands on #B9BDC3', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 0, 0, 0);
      expect(out[0], closeTo(185, 3));
      expect(out[1], closeTo(189, 3));
      expect(out[2], closeTo(195, 3));
    });
    test('illustration hue survives: red stays red', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 255, 0, 0);
      expect(out[0], greaterThan(200));
      expect(out[1], lessThan(160));
      expect(out[2], lessThan(170));
    });
  });

  group('palettes', () {
    test('paper / parchment are light, night is dark', () {
      expect(ReadingPalette.paper.brightness, Brightness.light);
      expect(ReadingPalette.parchment.brightness, Brightness.light);
      expect(ReadingPalette.night.brightness, Brightness.dark);
    });
    test('light themes use pure black text, night stays light', () {
      expect(ReadingPalette.paper.primaryText, const Color(0xFF000000));
      expect(ReadingPalette.parchment.primaryText, const Color(0xFF000000));
      // Night must never flip to black (unreadable on the dark canvas).
      expect(ReadingPalette.night.primaryText.computeLuminance(),
          greaterThan(0.4));
    });
    test('light palettes use a multiply tint, night uses the matrix', () {
      expect(ReadingPalette.paper.pageTint, isNotNull);
      expect(ReadingPalette.paper.nightMatrix, isNull);
      expect(ReadingPalette.parchment.pageTint, const Color(0xFFF5ECD4));
      expect(ReadingPalette.night.nightMatrix, isNotNull);
      expect(ReadingPalette.night.pageColorFilter, isA<ColorFilter>());
    });
    test('readingPaletteFor maps concrete themes', () {
      expect(readingPaletteFor(ReadingTheme.paper).theme, ReadingTheme.paper);
      expect(readingPaletteFor(ReadingTheme.parchment).theme,
          ReadingTheme.parchment);
      expect(readingPaletteFor(ReadingTheme.night).theme, ReadingTheme.night);
    });
  });

  group('AppTheme.forReadingTheme', () {
    test('night yields dark brightness and canvas surface', () {
      final t = AppTheme.forReadingTheme(ReadingTheme.night);
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, ReadingPalette.night.canvas);
      expect(
          t.colorScheme.surfaceContainerLow, ReadingPalette.night.pageCard);
      expect(t.colorScheme.surfaceContainerHighest,
          ReadingPalette.night.placeholder);
      expect(t.extension<ReadingPalette>()?.theme, ReadingTheme.night);
    });
    test('parchment yields light brightness and canvas surface', () {
      final t = AppTheme.forReadingTheme(ReadingTheme.parchment);
      expect(t.brightness, Brightness.light);
      expect(t.scaffoldBackgroundColor, ReadingPalette.parchment.canvas);
      expect(
          t.extension<ReadingPalette>()?.theme, ReadingTheme.parchment);
    });
    test('stock light/dark themes carry a default palette', () {
      expect(AppTheme.light().extension<ReadingPalette>()?.theme,
          ReadingTheme.paper);
      expect(AppTheme.dark().extension<ReadingPalette>()?.theme,
          ReadingTheme.night);
    });
  });
}
