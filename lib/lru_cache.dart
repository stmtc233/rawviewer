import 'dart:collection';

class LruCache<K, V> {
  final int maximumSize;
  final int Function(V value)? sizeOf;
  final LinkedHashMap<K, V> _cache;
  int _currentSize = 0;

  /// [maximumSize] is the max size of the cache.
  /// If [sizeOf] is provided, size is calculated by sum of sizeOf(value).
  /// If [sizeOf] is null, size is the number of entries.
  LruCache(this.maximumSize, {this.sizeOf}) : _cache = LinkedHashMap<K, V>();

  V? get(K key) {
    if (!_cache.containsKey(key)) return null;

    // Move to end (most recently used)
    final value = _cache.remove(key) as V;
    _cache[key] = value;
    return value;
  }

  void put(K key, V value) {
    final itemSize = sizeOf != null ? sizeOf!(value) : 1;

    // If the item itself is bigger than the cache, don't cache it (or clear everything and cache only this one?)
    // Usually, we just don't cache if it's too big, but let's be flexible.
    // If it's too big, we might still want to cache it as the only item if it fits?
    // Let's stick to simple eviction.

    if (_cache.containsKey(key)) {
      final oldValue = _cache.remove(key) as V;
      _currentSize -= sizeOf != null ? sizeOf!(oldValue) : 1;
    }

    _cache[key] = value;
    _currentSize += itemSize;

    while (_currentSize > maximumSize && _cache.isNotEmpty) {
      final keyToRemove = _cache.keys.first;
      final valueToRemove = _cache.remove(keyToRemove) as V;
      _currentSize -= sizeOf != null ? sizeOf!(valueToRemove) : 1;
    }
  }

  void clear() {
    _cache.clear();
    _currentSize = 0;
  }

  bool containsKey(K key) => _cache.containsKey(key);

  int get size => _currentSize;
  int get length => _cache.length;
}
