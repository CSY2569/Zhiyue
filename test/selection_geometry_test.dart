import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Synthetic char boxes: two lines of text.
/// Line 1 (y=0.10): a b c d at x = 0.10/0.20/0.30/0.40
/// Line 2 (y=0.20): e f g   at x = 0.10/0.20/0.30
CharBox box(String ch, double x, double y,
        {double w = 0.01, double h = 0.02}) =>
    CharBox(char: ch, x: x, y: y, w: w, h: h);

List<CharBox> sample() => [
      box('a', 0.10, 0.10),
      box('b', 0.20, 0.10),
      box('c', 0.30, 0.10),
      box('d', 0.40, 0.10),
      box('e', 0.10, 0.20),
      box('f', 0.20, 0.20),
      box('g', 0.30, 0.20),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('charIndexAt (FEATURES 4.1.1 hit-testing)', () {
    test('hits the nearest character inside a line', () {
      final boxes = sample();
      expect(charIndexAt(boxes, const Offset(0.21, 0.11)), 1); // b
      expect(charIndexAt(boxes, const Offset(0.34, 0.11)), 2); // c (gap snaps)
      expect(charIndexAt(boxes, const Offset(0.15, 0.21)), 4); // e
      expect(charIndexAt(boxes, const Offset(0.31, 0.21)), 6); // g
    });

    test('gap between lines returns -1 (whitespace tap clears)', () {
      final boxes = sample();
      // y = 0.16 sits between line 1 (y 0.10-0.12) and line 2 (y 0.20-0.22).
      expect(charIndexAt(boxes, const Offset(0.25, 0.16)), -1);
      expect(charIndexAt(boxes, const Offset(0.90, 0.90)), -1);
    });

    test('empty box list returns -1', () {
      expect(charIndexAt(const [], const Offset(0.5, 0.5)), -1);
    });
  });

  group('selectionText (FEATURES 4.1.1)', () {
    test('forward range concatenates in document order', () {
      expect(selectionText(sample(), 1, 3), 'bcd');
    });

    test('backward range yields the same text (reverse drag)', () {
      expect(selectionText(sample(), 3, 1), 'bcd');
    });

    test('cross-line range', () {
      expect(selectionText(sample(), 2, 5), 'cdef');
    });
  });

  group('selectionRects (FEATURES 4.3.1: per-line precision)', () {
    test('single-line selection yields one tight rect', () {
      final rects = selectionRects(sample(), 0, 3);
      expect(rects, hasLength(1));
      expect(rects[0].x, closeTo(0.10, 1e-9));
      expect(rects[0].y, closeTo(0.10, 1e-9));
      // right edge = d.x + d.w = 0.41
      expect(rects[0].w, closeTo(0.31, 1e-9));
      expect(rects[0].h, closeTo(0.02, 1e-9));
    });

    test('cross-line selection yields one rect per line, top to bottom', () {
      final forward = selectionRects(sample(), 1, 6);
      final backward = selectionRects(sample(), 6, 1);
      expect(forward, hasLength(2));
      expect(forward, backward); // direction-independent
      // Line 1: b..d -> x 0.20 .. 0.41
      expect(forward[0].x, closeTo(0.20, 1e-9));
      expect(forward[0].w, closeTo(0.21, 1e-9));
      // Line 2: e..g -> x 0.10 .. 0.31
      expect(forward[1].x, closeTo(0.10, 1e-9));
      expect(forward[1].w, closeTo(0.21, 1e-9));
      expect(forward[0].y, lessThan(forward[1].y)); // ordered
    });

    test('selection starting mid-line then spanning lines', () {
      final rects = selectionRects(sample(), 3, 5);
      expect(rects, hasLength(2));
      expect(rects[0].x, closeTo(0.40, 1e-9)); // line 1: d only
      expect(rects[1].x, closeTo(0.10, 1e-9)); // line 2: e,f (0.10..0.21)
      expect(rects[1].w, closeTo(0.11, 1e-9));
    });

    test('empty input yields no rects', () {
      expect(selectionRects(const [], 0, 3), isEmpty);
    });

    test('mixed-case line merges into one rect (real pdfium output)', () {
      // Real extract_text data: 'D' (capital) sits ~0.0035 higher than the
      // lowercase glyphs on the same baseline. A fixed-tolerance clustering
      // would split this into two overlapping rects and double-draw marks.
      final mixed = [
        box('D', 0.0974, 0.0860, w: 0.0162, h: 0.0137),
        box('u', 0.1169, 0.0897, w: 0.0128, h: 0.0101),
        box('m', 0.1332, 0.0895, w: 0.0206, h: 0.0101),
        box('m', 0.1572, 0.0895, w: 0.0206, h: 0.0101),
        box('y', 0.1799, 0.0897, w: 0.0144, h: 0.0139),
      ];
      final rects = selectionRects(mixed, 0, 4);
      expect(rects, hasLength(1)); // one line -> one rect -> one mark
      expect(rects[0].x, closeTo(0.0974, 1e-9));
      expect(rects[0].y, closeTo(0.0860, 1e-9));
      // right edge = y.x + y.w = 0.1943
      expect(rects[0].w, closeTo(0.0969, 1e-9));
      // bottom = max(y+h) = 0.1036 ('y' has a descender) -> h from top 0.0860
      expect(rects[0].h, closeTo(0.0176, 1e-9));
    });

    test('adjacent lines never merge even with tight line gap', () {
      // Line 1 bottom (0.14) vs line 2 top (0.13) would overlap only if the
      // gap were negative; here the gap is small but positive.
      final tight = [
        box('a', 0.10, 0.10, w: 0.02, h: 0.03), // 0.10 .. 0.13
        box('b', 0.10, 0.135, w: 0.02, h: 0.03), // 0.135 .. 0.165
      ];
      expect(selectionRects(tight, 0, 1), hasLength(2));
    });
  });

  // --- OCR line-level selection (FEATURES 7.1.3) ---

  group('isLineLevelBoxes', () {
    test('true when any box char is multi-character (OCR)', () {
      expect(isLineLevelBoxes([CharBox(char: 'hello', x: 0, y: 0, w: 1, h: 0.1)]),
          isTrue);
    });
    test('false when all boxes are single-char (native PDF)', () {
      expect(isLineLevelBoxes([box('a', 0.1, 0.1)]), isFalse);
    });
  });

  group('encode/decode line positions', () {
    test('round-trips line index and char offset', () {
      for (final (line, off) in [(0, 0), (3, 7), (12, 999), (0, 42)]) {
        final encoded = encodeLinePos(line, off);
        expect(decodeLineIndex(encoded), line);
        expect(decodeCharOffset(encoded), off);
      }
    });
  });

  group('selectionTextFromLines', () {
    final lineBoxes = [
      CharBox(char: '复杂指令集', x: 0.1, y: 0.1, w: 0.6, h: 0.04),
      CharBox(char: '(CISC)', x: 0.1, y: 0.16, w: 0.3, h: 0.04),
    ];
    test('single-line substring', () {
      final start = encodeLinePos(0, 1); // '杂'
      final end = encodeLinePos(0, 3);   // '令'
      expect(selectionTextFromLines(lineBoxes, start, end), '杂指令');
    });
    test('backward drag yields same text', () {
      final start = encodeLinePos(0, 3);
      final end = encodeLinePos(0, 1);
      expect(selectionTextFromLines(lineBoxes, start, end), '杂指令');
    });
    test('cross-line range', () {
      final start = encodeLinePos(0, 2); // '指' on line 0
      final end = encodeLinePos(1, 2);   // 'I' on line 1 -> inclusive -> '(CI'
      expect(selectionTextFromLines(lineBoxes, start, end), '指令集(CI');
    });
  });

  group('selectionRectsFromLines', () {
    test('returns one rect per selected line segment', () {
      // Uses TextPainter so needs a widget test binding.
      final boxes = [
        CharBox(char: '复杂指令集', x: 0.1, y: 0.1, w: 0.6, h: 0.04),
        CharBox(char: '(CISC)', x: 0.1, y: 0.16, w: 0.3, h: 0.04),
      ];
      final layouts = [
        LineLayout(boxes[0], 800),
        LineLayout(boxes[1], 800),
      ];
      addTearDown(() { layouts[0].dispose(); layouts[1].dispose(); });
      final start = encodeLinePos(0, 1);
      final end = encodeLinePos(0, 3);
      final rects = selectionRectsFromLines(boxes, layouts, start, end);
      expect(rects, hasLength(1));
      // The rect should be within the line's vertical bounds.
      expect(rects[0].y, closeTo(0.1, 1e-9));
      expect(rects[0].h, closeTo(0.04, 1e-9));
      // The rect should be a sub-range (not the full line width).
      expect(rects[0].w, lessThan(0.6));
      expect(rects[0].x, greaterThan(0.1));
    });

    test('long line tail stays reachable (regression: maxWidth truncation)',
        () {
      // A line whose rendered text is WIDER than its box: constraining the
      // layout to the box width used to truncate the tail, making the second
      // half of the line unselectable. Natural-width layout keeps every
      // character reachable.
      final boxes = [
        CharBox(
          char: '复杂指令集与精简指令集的对比分析表',
          x: 0.1,
          y: 0.1,
          w: 0.3, // narrow box -- rendered text overflows it
          h: 0.04,
        ),
      ];
      final layout = LineLayout(boxes[0], 800);
      addTearDown(() => layout.dispose());
      // Click far right of the line box (the overflowing text region): the
      // LAST character must be reachable, not clamped to a truncated tail.
      final last = boxes[0].char.length - 1;
      final rightNorm = boxes[0].x + boxes[0].w + 0.1; // beyond box, in text
      final encoded = lineIndexAt(
        boxes,
        [layout],
        Offset(rightNorm, boxes[0].y + boxes[0].h / 2),
      );
      expect(encoded, isNot(-1), reason: 'tail must be hit-testable');
      expect(decodeLineIndex(encoded), 0);
      expect(decodeCharOffset(encoded), last,
          reason: 'click at the text tail must select the last character');
    });

    test('second half of a wide box is selectable (regression: display-scale '
        'hit-test mismatch)', () {
      // The text layer DISPLAYS the text scaled to fill the line box. If
      // hit-testing used the text's natural (narrower) width instead, the
      // right half of the visible line was unreachable -- clicking it
      // saturated at ~60% of the text ("只能选择前半部分"). Hit-testing must
      // use the same box-relative scale as the display.
      final text = '复杂指令集与精简指令集(CISC/RISC-V)对比分析';
      final boxes = [
        CharBox(
          char: text,
          x: 0.1,
          y: 0.1,
          w: 0.8, // wide box -- measured text (~0.49 of page) is narrower
          h: 0.04,
        ),
      ];
      final layout = LineLayout(boxes[0], 800);
      addTearDown(() => layout.dispose());
      final last = text.length - 1;
      // Click at 5 positions across the second half of the line box: every
      // one must resolve to a character beyond the box's first half.
      for (var i = 6; i <= 10; i++) {
        final normX = boxes[0].x + boxes[0].w * (i / 10);
        final encoded = lineIndexAt(
          boxes,
          [layout],
          Offset(normX, boxes[0].y + boxes[0].h / 2),
        );
        expect(encoded, isNot(-1), reason: 'normX=$normX must hit the line');
        final off = decodeCharOffset(encoded);
        expect(off, greaterThanOrEqualTo(text.length ~/ 2),
            reason: 'normX=$normX must reach the second half, got offset $off');
      }
      // The far right of the box reaches the last character.
      final end = lineIndexAt(
        boxes,
        [layout],
        Offset(boxes[0].x + boxes[0].w - 0.001, boxes[0].y + boxes[0].h / 2),
      );
      expect(decodeCharOffset(end), last,
          reason: 'right edge of the box must select the last character');
    });
  });
}
