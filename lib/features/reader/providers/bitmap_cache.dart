import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';

/// Cache key: (bookId, page, renderZoom). Pages are 0-indexed.
typedef _CacheKey = ({int bookId, int page, double renderZoom});

/// LRU bitmap cache for rendered PDF pages (TECH_ROADMAP §3.1).
///
/// Pages are rendered at a resolution that follows the user zoom, quantized
/// to 0.5 steps (0.5x / 1.0x / 1.5x / 2.0x / ... / 4.0x): zooming in
/// re-renders at a higher resolution so the page stays sharp (FEATURES 3.6.2
/// "页面高 DPI canvas 渲染 + 文本层，缩放不模糊"), zooming out keeps the
/// coarser tier. LRU cap of ~20 entries (~180MB at 9MB/page for A4 RGBA).
class BitmapCache {
  BitmapCache(this._repo);

  final ReaderRepository _repo;
  final LinkedHashMap<_CacheKey, ui.Image> _cache = LinkedHashMap();

  static const int _maxEntries = 20;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 4.0;

  /// Quantizes a zoom factor to a 0.5 step within [0.5, 4.0].
  /// Multiple zooms sharing a tier reuse the same cached bitmap.
  static double quantizeZoom(double zoom) {
    final q = (zoom * 2).round() / 2;
    return q.clamp(_minZoom, _maxZoom);
  }

  /// Returns the cached image for the page, or renders + caches it.
  /// `zoom` is the user zoom; the tier is quantized internally. `dpiScale`
  /// is the device pixel ratio for high-DPI output.
  Future<ui.Image?> getOrFetch({
    required int bookId,
    required int page,
    required double zoom,
    required double dpiScale,
  }) async {
    final renderZoom = quantizeZoom(zoom);
    final key = (bookId: bookId, page: page, renderZoom: renderZoom);

    // Cache hit: move to end (most-recently-used).
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached;
      return cached;
    }

    // Miss: render in Rust and decode.
    try {
      final result =
          await _repo.renderPage(bookId, page, renderZoom, dpiScale);
      if (result.error != null || result.rgba.isEmpty) return null;

      final image = await _decodeRgba(result.width, result.height, result.rgba);
      if (image == null) return null;

      _evictIfNeeded();
      _cache[key] = image;
      return image;
    } catch (_) {
      return null;
    }
  }

  /// Decode raw RGBA bytes into a [ui.Image] via [ui.decodeImageFromPixels].
  Future<ui.Image?> _decodeRgba(int width, int height, Uint8List rgba) {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      rgba,
      width,
      height,
      ui.PixelFormat.rgba8888,
      (img) => completer.complete(img),
    );
    return completer.future;
  }

  void _evictIfNeeded() {
    while (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}

/// Riverpod provider for the singleton [BitmapCache].
final bitmapCacheProvider = Provider<BitmapCache>((ref) {
  return BitmapCache(ref.read(readerRepositoryProvider));
});
