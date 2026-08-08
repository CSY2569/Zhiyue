import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/reader/widgets/hit_highlight_layer.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Two visual lines of boxes (line 2 shares y with line 1 to prove the
/// vertical-overlap clustering keeps same-line hits together).
List<CharBox> _page() => const [
      // Line 1: 量子计算入门
      CharBox(char: '量', x: 0.0, y: 0.1, w: 0.05, h: 0.05),
      CharBox(char: '子', x: 0.05, y: 0.1, w: 0.05, h: 0.05),
      CharBox(char: '计', x: 0.10, y: 0.1, w: 0.05, h: 0.05),
      CharBox(char: '算', x: 0.15, y: 0.1, w: 0.05, h: 0.05),
      CharBox(char: '入', x: 0.20, y: 0.1, w: 0.05, h: 0.05),
      CharBox(char: '门', x: 0.25, y: 0.1, w: 0.05, h: 0.05),
      // Line 2: 量子纠缠
      CharBox(char: '量', x: 0.0, y: 0.5, w: 0.05, h: 0.05),
      CharBox(char: '子', x: 0.05, y: 0.5, w: 0.05, h: 0.05),
      CharBox(char: '纠', x: 0.10, y: 0.5, w: 0.05, h: 0.05),
      CharBox(char: '缠', x: 0.15, y: 0.5, w: 0.05, h: 0.05),
      // Line 3: Deep Learning in English (case-insensitive match)
      CharBox(char: 'D', x: 0.0, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'e', x: 0.03, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'e', x: 0.06, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'p', x: 0.09, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'L', x: 0.12, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'e', x: 0.15, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'a', x: 0.18, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'r', x: 0.21, y: 0.9, w: 0.03, h: 0.05),
      CharBox(char: 'n', x: 0.24, y: 0.9, w: 0.03, h: 0.05),
    ];

void main() {
  test('hitRects finds every occurrence, one rect per line cluster', () {
    final rects = hitRects(_page(), '量子');
    // Two occurrences on two different lines -> two line rects.
    expect(rects, hasLength(2));
    // Each rect spans the two matched chars.
    expect(rects[0].w, closeTo(0.10, 1e-9));
    expect(rects[1].w, closeTo(0.10, 1e-9));
    // Different vertical positions (line 1 vs line 2).
    expect(rects[0].y, isNot(rects[1].y));
  });

  test('hitRects matches case-insensitively for latin text', () {
    final rects = hitRects(_page(), 'deep');
    expect(rects, hasLength(1));
    expect(rects.single.y, closeTo(0.9, 1e-9));
    expect(rects.single.w, closeTo(0.12, 1e-9));
  });

  test('hitRects ignores empty queries and misses', () {
    expect(hitRects(_page(), '   '), isEmpty);
    expect(hitRects(_page(), '不存在'), isEmpty);
    expect(hitRects(const [], '量子'), isEmpty);
  });
}
