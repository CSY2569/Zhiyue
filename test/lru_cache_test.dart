import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/lru_cache.dart';

void main() {
  group('LruCache entry cap', () {
    test('evicts the oldest when the entry cap is exceeded', () {
      final evicted = <int>[];
      final cache = LruCache<int, String>(
        maxEntries: 2,
        onEvict: (k, _) => evicted.add(k),
      );
      cache.put(1, 'a');
      cache.put(2, 'b');
      cache.get(1); // refresh: 2 is now oldest
      cache.put(3, 'c');

      expect(cache.length, 2);
      expect(cache.containsKey(2), isFalse);
      expect(evicted, [2]);
    });
  });

  group('LruCache byte budget', () {
    test('evicts until the byte budget fits', () {
      final evicted = <int>[];
      final cache = LruCache<int, int>(
        maxEntries: 100,
        maxBytes: 100,
        sizeOf: (_, size) => size,
        onEvict: (k, _) => evicted.add(k),
      );
      cache.put(1, 40);
      cache.put(2, 40);
      expect(cache.bytes, 80);

      cache.put(3, 40); // 120 > 100 -> evict 1
      expect(cache.length, 2);
      expect(cache.bytes, 80);
      expect(evicted, [1]);
      expect(cache.containsKey(2), isTrue);
      expect(cache.containsKey(3), isTrue);
    });

    test('an oversized entry evicts everything else but is kept', () {
      final cache = LruCache<int, int>(
        maxEntries: 100,
        maxBytes: 100,
        sizeOf: (_, size) => size,
      );
      cache.put(1, 60);
      cache.put(2, 90); // 150 -> evict 1
      expect(cache.length, 1);
      expect(cache.containsKey(2), isTrue);
      expect(cache.bytes, 90);
    });

    test('replacing a key does not double-count its bytes', () {
      final cache = LruCache<int, int>(
        maxEntries: 100,
        maxBytes: 100,
        sizeOf: (_, size) => size,
      );
      cache.put(1, 40);
      cache.put(1, 30);
      expect(cache.length, 1);
      expect(cache.bytes, 30);

      cache.put(2, 50);
      expect(cache.bytes, 80); // 30 + 50, not 40 + 30 + 50
      expect(cache.containsKey(1), isTrue);
    });

    test('remove and clear keep the byte count exact', () {
      final cache = LruCache<int, int>(
        maxEntries: 100,
        maxBytes: 800,
        sizeOf: (_, size) => size,
      );
      cache.put(1, 100);
      cache.put(2, 200);
      expect(cache.bytes, 300);

      cache.remove(1);
      expect(cache.bytes, 200);
      cache.clear();
      expect(cache.bytes, 0);
      expect(cache.length, 0);
    });

    test('without a budget, bytes stay zero', () {
      final cache = LruCache<int, int>(maxEntries: 2);
      cache.put(1, 999);
      expect(cache.bytes, 0);
      expect(cache.length, 1);
    });
  });
}
