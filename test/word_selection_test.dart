import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

List<CharBox> _boxes(String text) => [
      for (var i = 0; i < text.length; i++)
        CharBox(
          char: text[i],
          x: i / text.length,
          y: 0.1,
          w: 1 / text.length,
          h: 0.04,
        ),
    ];

void main() {
  group('script detection', () {
    test('CJK, kana, hangul and full-width punctuation are CJK', () {
      for (final c in ['中', '文', 'あ', 'カ', '한', '，', '。', '（']) {
        expect(isCjkChar(c), isTrue, reason: c);
      }
      expect(isCjkChar('A'), isFalse);
      expect(isCjkChar(' '), isFalse);
    });

    test('word characters cover letters, digits, apostrophes, hyphens', () {
      for (final c in ['a', 'Z', '9', "'", '’', '-', '_']) {
        expect(isWordChar(c), isTrue, reason: c);
      }
      for (final c in [' ', '.', ',', '。', '中']) {
        expect(isWordChar(c), isFalse, reason: c);
      }
    });
  });

  group('wordRangeAt (per-char boxes)', () {
    test('selects the whole Latin word from any position inside it', () {
      final boxes = _boxes('hello world');
      expect(wordRangeAt(boxes, 0), (0, 4));
      expect(wordRangeAt(boxes, 2), (0, 4));
      expect(wordRangeAt(boxes, 4), (0, 4));
      expect(wordRangeAt(boxes, 6), (6, 10));
      expect(wordRangeAt(boxes, 10), (6, 10));
    });

    test('whitespace and punctuation select only themselves', () {
      final boxes = _boxes('ab, cd');
      expect(wordRangeAt(boxes, 2), (2, 2)); // comma
      expect(wordRangeAt(boxes, 3), (3, 3)); // space
      expect(wordRangeAt(boxes, 4), (4, 5));
    });

    test('CJK selects one character at a time', () {
      final boxes = _boxes('中文测试');
      expect(wordRangeAt(boxes, 1), (1, 1));
      expect(wordRangeAt(boxes, 3), (3, 3));
    });

    test('keeps hyphenated compounds together', () {
      // "state-of-the-art" spans 0..15, space at 16, "x" at 17.
      final boxes = _boxes('state-of-the-art x');
      expect(wordRangeAt(boxes, 8), (0, 15));
      expect(wordRangeAt(boxes, 16), (16, 16)); // space
      expect(wordRangeAt(boxes, 17), (17, 17));
    });
  });

  group('wordRangeInLine (OCR line boxes)', () {
    test('finds the word inside a line of mixed text', () {
      const text = '这是 PDF 文件';
      // 'PDF' occupies offsets 3..5.
      expect(wordRangeInLine(text, 4), (3, 5));
      // CJK characters stand alone.
      expect(wordRangeInLine(text, 1), (1, 1));
      // Space selects itself.
      expect(wordRangeInLine(text, 2), (2, 2));
    });

    test('handles the empty line and out-of-range offsets', () {
      expect(wordRangeInLine('', 5), (0, 0));
      expect(wordRangeInLine('abc', 99), (0, 2));
    });
  });

  group('wordRangeAtEncoded', () {
    test('expands within the line and keeps the encoded line index', () {
      final boxes = [
        CharBox(char: 'hello world', x: 0.1, y: 0.1, w: 0.5, h: 0.04),
        CharBox(char: 'second line', x: 0.1, y: 0.2, w: 0.5, h: 0.04),
      ];
      final encoded = encodeLinePos(0, 8); // inside "world"
      final (lo, hi) = wordRangeAtEncoded(boxes, encoded);
      expect(decodeLineIndex(lo), 0);
      expect(decodeLineIndex(hi), 0);
      expect(decodeCharOffset(lo), 6);
      expect(decodeCharOffset(hi), 10);
    });
  });
}
