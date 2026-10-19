import 'dart:collection';

/// Small insertion-ordered LRU map shared by the in-memory page caches.
///
/// `get` refreshes recency; `put` evicts the oldest entries beyond
/// [maxEntries]. [onEvict] lets a cache dispose resources (e.g. `ui.Image`);
/// caches whose values are owned by the finalizer pass null.
class LruCache<K, V> {
  LruCache({required this.maxEntries, this.onEvict})
      : assert(maxEntries > 0);

  final int maxEntries;
  final void Function(K key, V value)? onEvict;

  final LinkedHashMap<K, V> _entries = LinkedHashMap();

  int get length => _entries.length;
  Iterable<K> get keys => _entries.keys;
  Iterable<V> get values => _entries.values;

  V? get(K key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value; // refresh recency
    return value;
  }

  /// Whether [key] is cached without refreshing its recency.
  bool containsKey(K key) => _entries.containsKey(key);

  void put(K key, V value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest);
      if (evicted != null) onEvict?.call(oldest, evicted);
    }
  }

  V? remove(K key) {
    final value = _entries.remove(key);
    if (value != null) onEvict?.call(key, value);
    return value;
  }

  /// Remove entries matching [test]; evicted values go through [onEvict].
  void removeWhere(bool Function(K key, V value) test) {
    final doomed = [
      for (final entry in _entries.entries)
        if (test(entry.key, entry.value)) entry.key,
    ];
    for (final key in doomed) {
      final value = _entries.remove(key);
      if (value != null) onEvict?.call(key, value);
    }
  }

  /// Drop every entry, notifying [onEvict] for each.
  void clear() {
    for (final entry in _entries.entries) {
      onEvict?.call(entry.key, entry.value);
    }
    _entries.clear();
  }
}
