/// Small LRU helpers shared by the in-memory caches (char boxes, OCR
/// low-confidence lines, thumbnails).
library;

/// Touch [key] in [map]: the re-inserted entry moves to the tail, so the
/// map's insertion order doubles as LRU order (oldest first). Entries beyond
/// [max] are evicted from the front. Returns the new map.
Map<K, V> lruTouch<K, V>(Map<K, V> map, K key, V value, int max) {
  final next = Map<K, V>.from(map)
    ..remove(key)
    ..[key] = value;
  while (next.length > max) {
    next.remove(next.keys.first);
  }
  return next;
}