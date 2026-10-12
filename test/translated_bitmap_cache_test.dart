import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/bilingual/providers/translated_bitmap_cache.dart';

void main() {
  group('译文位图宽度分档', () {
    test('按 256px 桶量化，小变化复用同一档', () {
      expect(TranslatedBitmapCache.widthTier(900), 1024);
      expect(TranslatedBitmapCache.widthTier(950), 1024);
      expect(TranslatedBitmapCache.widthTier(1100), 1024);
      expect(TranslatedBitmapCache.widthTier(1200), 1280);
    });

    test('越界钳制到 [256, 4096]', () {
      expect(TranslatedBitmapCache.widthTier(50), 256);
      expect(TranslatedBitmapCache.widthTier(9999), 4096);
    });
  });
}