import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/reader/providers/bitmap_cache.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart';

void main() {
  group('zoom tier quantization', () {
    test('rounds UP so the first render is already sharp', () {
      // The default reader zoom (1.2) used to snap to 1.0 and then re-render
      // at 1.5; now it starts at 1.5 directly.
      expect(BitmapCache.quantizeZoom(1.2), 1.5);
      expect(BitmapCache.quantizeZoom(1.5), 1.5);
      expect(BitmapCache.quantizeZoom(1.51), 2.0);
      expect(BitmapCache.quantizeZoom(2.0), 2.0);
    });

    test('clamps to the supported range', () {
      expect(BitmapCache.quantizeZoom(0.1), 0.5);
      expect(BitmapCache.quantizeZoom(9.0), 4.0);
    });
  });

  group('adaptive render DPI', () {
    test('caps browsing renders at 2x on a high-DPI phone', () {
      expect(effectiveRenderDpi(3.0, 1.0), 2.0);
      expect(effectiveRenderDpi(3.5, 1.2), 2.0);
      expect(effectiveRenderDpi(2.75, 1.4), 2.0);
    });

    test('uses the full device DPR once zoomed in for detail', () {
      expect(effectiveRenderDpi(3.0, 1.5), 3.0);
      expect(effectiveRenderDpi(3.5, 4.0), 3.5);
    });

    test('never renders below 1x on a low-DPI display', () {
      expect(effectiveRenderDpi(1.0, 1.0), 1.0);
    });
  });
}
