import 'dart:collection';

/// Small insertion-ordered LRU map shared by the in-memory page caches.
///
/// `get` refreshes recency; `put` evicts the oldest entries beyond
/// [maxEntries]. [onEvict] lets a cache dispose resources (e.g. `ui.Image`);
/// caches whose values are owned by the finalizer pass null.
///
/// Optional byte budget: when [maxBytes] and [sizeOf] are set, the cache also
/// evicts oldest-first until the total reported size fits. This is what keeps
/// decoded page bitmaps inside a phone's memory budget -- an entry count alone
/// cannot, because page cost varies with DPI and zoom tier.
class LruCache<K, V> {
  LruCache({
    required this.maxEntries,
    this.onEvict,
    this.maxBytes,
    this.sizeOf,
  })  : assert(maxEntries > 0),
        assert(maxBytes == null || sizeOf != null);

  final int maxEntries;
  final void Function(K key, V value)? onEvict;

  /// Optional byte budget (e.g. decoded image memory).
  final int? maxBytes;

  /// Cost of one entry in the same unit as [maxBytes].
  final int Function(K key, V value)? sizeOf;

  final LinkedHashMap<K, V> _entries = LinkedHashMap();

  /// Cost of each entry, kept alongside so eviction does not need [sizeOf] to
  /// be deterministic (a decoded image's size is fixed, but frees elsewhere
  /// could make re-measuring stale).
  final Map<K, int> _costs = {};

  int _bytes = 0;

  /// Current accounted bytes (0 when no [maxBytes] was configured).
  int get bytes => _bytes;

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
    final replaced = _entries.remove(key);
    if (replaced != null) _release(key, replaced);
    _entries[key] = value;
    _retain(key, value);
    while (_entries.length > maxEntries ||
        (maxBytes != null && _bytes > maxBytes!)) {
      final oldest = _entries.keys.first;
      final evicted = _entries.remove(oldest);
      if (evicted != null) {
        _release(oldest, evicted);
        onEvict?.call(oldest, evicted);
      }
    }
  }

  V? remove(K key) {
    final value = _entries.remove(key);
    if (value != null) {
      _release(key, value);
      onEvict?.call(key, value);
    }
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
      if (value != null) {
        _release(key, value);
        onEvict?.call(key, value);
      }
    }
  }

  /// Drop every entry, notifying [onEvict] for each.
  void clear() {
    for (final entry in _entries.entries) {
      onEvict?.call(entry.key, entry.value);
    }
    _entries.clear();
    _costs.clear();
    _bytes = 0;
  }

  void _retain(K key, V value) {
    if (maxBytes == null) return;
    final cost = sizeOf!(key, value);
    _costs[key] = cost;
    _bytes += cost;
  }

  void _release(K key, V value) {
    if (maxBytes == null) return;
    _bytes -= _costs.remove(key) ?? sizeOf!(key, value);
    if (_bytes < 0) _bytes = 0;
  }
}
