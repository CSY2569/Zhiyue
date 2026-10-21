import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';

void main() {
  group('golden proportions', () {
    test('cover ratio is the portrait sqrt-2 of real book pages', () {
      // A5 (148x210), 32开 (130x184) and B5 (176x250) are all within ~1% of
      // this ratio -- φ would make every cover noticeably too tall.
      expect(Golden.coverRatio, closeTo(0.7071, 0.001));
      expect(Golden.sqrt2 * Golden.coverRatio, closeTo(1.0, 0.001));
      expect(148 / 210, closeTo(Golden.coverRatio, 0.006));
      expect(130 / 184, closeTo(Golden.coverRatio, 0.007));
    });

    test('the spacing ladder steps by roughly phi', () {
      // s4 is the 4dp grid unit; the φ ladder starts at s8 (Fibonacci:
      // 8, 13, 21, 34, 55, 89).
      const ladder = [
        Golden.s8,
        Golden.s13,
        Golden.s21,
        Golden.s34,
        Golden.s55,
        Golden.s89,
      ];
      for (var i = 1; i < ladder.length; i++) {
        final ratio = ladder[i] / ladder[i - 1];
        expect(ratio, inInclusiveRange(1.5, 1.72),
            reason: '${ladder[i - 1]} -> ${ladder[i]}');
      }
    });
  });

  group('grid solving', () {
    test('a phone gets 1-2 columns near the target width', () {
      final phone = Golden.gridFor(360 - 13 * 2);
      expect(phone.columns, inInclusiveRange(1, 2));
      expect(phone.cardWidth, greaterThan(120));
    });

    test('an 11" tablet (~776dp) gets a 2-3 column shelf', () {
      // The rail takes 208dp, leaving ~568dp for the grid.
      final pad = Golden.pagePaddingFor(776);
      final grid = Golden.gridFor(776 - 208 - pad * 2);
      expect(grid.columns, inInclusiveRange(2, 3));
      // Cards stay inside the target band instead of stretching to fill.
      expect(grid.cardWidth,
          inInclusiveRange(Golden.minCardWidth, Golden.maxCardWidth));
    });

    test('a desktop window adds columns, not card size', () {
      final pad = Golden.pagePaddingFor(1280);
      final grid = Golden.gridFor(1280 - Golden.railDefaultWidth - pad * 2);
      expect(grid.columns, greaterThanOrEqualTo(4));
      expect(grid.cardWidth,
          inInclusiveRange(Golden.minCardWidth, Golden.maxCardWidth));
    });

    test('degenerate widths never produce zero columns or negative cards', () {
      expect(Golden.gridFor(0).columns, 1);
      expect(Golden.gridFor(-100).cardWidth, greaterThan(0));
      expect(Golden.gridFor(10000).columns, lessThanOrEqualTo(16));
    });
  });

  group('cell geometry', () {
    test('cell height is cover height plus the fixed text block', () {
      const w = 184.0;
      final expected = w / Golden.coverRatio + Golden.textBlockHeight();
      expect(Golden.cellHeightFor(w), closeTo(expected, 0.001));
      // Cover is taller than it is wide (a portrait book).
      expect(w / Golden.coverRatio, greaterThan(w));
    });

    test('cell extent covers the cover plus the text block at 1.0 scale', () {
      // The card lays out [AspectRatio cover][Expanded text]. The grid cell
      // must be exactly the sum or the text block overflows by the
      // difference -- the 0.98px overflow seen on a tablet.
      for (final w in [152.0, 184.0, 216.0]) {
        final cover = w / Golden.coverRatio;
        final block = Golden.textBlockHeight(textScale: 1.0);
        expect(Golden.cellHeightFor(w), closeTo(cover + block, 0.01),
            reason: 'width $w');
        // The block must actually be able to hold two title lines + meta.
        expect(block, greaterThan(9 + 14 * 1.25 * 2 + 3 + 11 * 1.2));
      }
    });

    test('text block grows with accessibility font scaling, not with title',
        () {
      final normal = Golden.textBlockHeight();
      final scaled = Golden.textBlockHeight(textScale: 1.3);
      expect(scaled, greaterThan(normal));
      // Same formula for the cell, so the cover keeps its slot exactly.
      expect(
        Golden.cellHeightFor(184, textScale: 1.3) -
            Golden.cellHeightFor(184),
        closeTo(scaled - normal, 0.001),
      );
    });
  });

  group('rail width', () {
    test('scales with the window but stays a rail', () {
      expect(Golden.railWidthFor(0), Golden.railDefaultWidth);
      expect(Golden.railWidthFor(700), Golden.railDefaultWidth);
      expect(Golden.railWidthFor(1280), inInclusiveRange(208, 264));
      expect(Golden.railWidthFor(3000), lessThanOrEqualTo(264));
    });
  });
}
