import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/lru_cache.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/image_decoder.dart';

/// Cache key: (bookId, page, renderZoom). Pages are 0-indexed.
typedef _CacheKey = ({int bookId, int page, double renderZoom});

/// LRU bitmap cache for rendered PDF pages (TECH_ROADMAP §3.1).
///
/// Pages are rendered at a resolution that follows the user zoom, quantized
/// UP to 0.5 steps (0.5x / 1.0x / 1.5x / 2.0x / ... / 4.0x): zooming in
/// re-renders at a higher resolution so the page stays sharp (FEATURES 3.6.2
/// "页面高 DPI canvas 渲染 + 文本层，缩放不模糊"), zooming out keeps the
/// coarser tier.
///
/// Rounding UP matters: the old nearest-tier rounding rendered the default
/// 1.2x zoom at 1.0x and then immediately re-rendered at 1.5x to become
/// sharp ("stage-2 sharpen"). Every page therefore paid TWO full pdfium
/// renders plus two RGBA decodes on first view -- the single largest source
/// of page-flip jank. Ceiling puts the first render at the final tier. Eviction is bounded by BOTH an entry count and a byte budget:
/// decoded bitmaps are the app's largest allocation and a phone has far less
/// headroom than a desktop (the budget is chosen per platform).
///
/// Evicted images are NOT disposed here: a `_PageItem` may still be painting
/// the image it received (the list keeps a few items alive, and the item's own
/// state holds the strong reference), and disposing a `ui.Image` under a live
/// `RawImage` throws. Dropping the cache reference is enough -- the engine
/// releases the pixels once the last widget stops referencing it.
class BitmapCache {
  BitmapCache(this._repo, {int? byteBudget})
      : _cache = LruCache<_CacheKey, ui.Image>(
          maxEntries: _maxEntries,
          maxBytes: byteBudget ?? defaultByteBudget(),
          sizeOf: (_, image) => image.width * image.height * 4,
        );

  final ReaderRepository _repo;
  final LruCache<_CacheKey, ui.Image> _cache;

  /// Decoded-page memory budget. Mobile gets a smaller window than desktop:
  /// the same ~9MB A4 bitmap competes with the OCR models' working set there.
  static int defaultByteBudget() =>
      (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS)
          ? 96 * 1024 * 1024
          : 192 * 1024 * 1024;
  // In-flight renders keyed by the same cache key. Two callers requesting the
  // same page/tier before the first finishes share one Rust render (the
  // ListView re-layout from the scroll-alignment fix can otherwise fan out
  // many `_PageItem` loads for the same page at once).
  final Map<_CacheKey, Future<ui.Image?>> _pending = {};

  static const int _maxEntries = 20;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 4.0;

  /// Renders are serialized (pdfium has one global lock anyway) through a
  /// priority queue so a burst of cacheExtent neighbours can never delay the
  /// page the reader is actually looking at. Lower priority number wins.
  final List<_QueuedRender> _queue = [];
  int _queueSeq = 0;
  bool _rendering = false;

  /// Drops cached pages to free memory under system pressure.
  ///
  /// [keepPage] (0-indexed) is retained -- the page on screen must not blink
  /// out mid-scroll; everything else is released. Returns how many entries
  /// were dropped.
  int trim({int? keepPage}) {
    final before = _cache.length;
    _cache.removeWhere((key, _) => key.page != keepPage);
    return before - _cache.length;
  }

  /// Number of cached pages and their accounted bytes (diagnostics/tests).
  int get length => _cache.length;
  int get bytes => _cache.bytes;

  /// Quantizes a zoom factor UP to a 0.5 step within [0.5, 4.0].
  /// Multiple zooms sharing a tier reuse the same cached bitmap, and the
  /// bitmap is never smaller than the display needs (so the sharpen pass is
  /// a no-op for the common case).
  static double quantizeZoom(double zoom) {
    final q = (zoom * 2).ceil() / 2;
    return q.clamp(_minZoom, _maxZoom);
  }

  /// Returns the cached image for the page, or renders + caches it.
  /// `zoom` is the user zoom; the tier is quantized internally. `dpiScale`
  /// is the device pixel ratio for high-DPI output. Concurrent calls for the
  /// same key share a single in-flight render.
  Future<ui.Image?> getOrFetch({
    required int bookId,
    required int page,
    required double zoom,
    required double dpiScale,
    int priority = 1,
  }) async {
    final renderZoom = quantizeZoom(zoom);
    final key = (bookId: bookId, page: page, renderZoom: renderZoom);

    // Cache hit: refreshes recency.
    final cached = _cache.get(key);
    if (cached != null) return cached;

    // Miss: deduplicate concurrent renders of the same key. A second caller
    // awaiting the same future sees the same result (and the cache populated
    // by the first), so it never fires its own renderPage.
    final pending = _pending[key];
    if (pending != null) {
      // The page may have become visible after the neighbour request went
      // out: promote the queued job so it runs next.
      _promote(key, priority);
      return pending;
    }

    final future = _enqueue(key, priority, () => _render(key, bookId, page, renderZoom, dpiScale));
    _pending[key] = future;
    try {
      return await future;
    } finally {
      _pending.remove(key);
      _jobs.remove(key);
    }
  }

  final Map<_CacheKey, _QueuedRender> _jobs = {};

  /// Queues one render and returns its result. Only one render runs at a
  /// time; the next one is chosen by priority, then FIFO.
  Future<ui.Image?> _enqueue(
    _CacheKey key,
    int priority,
    Future<ui.Image?> Function() task,
  ) {
    final completer = Completer<ui.Image?>();
    final job = _QueuedRender(priority, _queueSeq++, () async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _jobs[key] = job;
    _queue.add(job);
    _pump();
    return completer.future;
  }

  /// Raises a queued job's priority (no-op when it already runs / is done).
  void _promote(_CacheKey key, int priority) {
    final job = _jobs[key];
    if (job == null) return;
    if (priority < job.priority) job.priority = priority;
  }

  void _pump() {
    if (_rendering) return;
    if (_queue.isEmpty) return;
    _queue.sort((a, b) =>
        a.priority != b.priority ? a.priority - b.priority : a.seq - b.seq);
    final next = _queue.removeAt(0);
    _rendering = true;
    next.run().whenComplete(() {
      _rendering = false;
      _pump();
    });
  }

  Future<ui.Image?> _render(
    _CacheKey key,
    int bookId,
    int page,
    double renderZoom,
    double dpiScale,
  ) async {
    // Miss: render in Rust and decode.
    try {
      final result =
          await _repo.renderPage(bookId, page, renderZoom, dpiScale);
      if (result.error != null || result.rgba.isEmpty) return null;

      final image =
          await decodeRgbaImage(result.width, result.height, result.rgba);
      if (image == null) return null;

      _cache.put(key, image);
      return image;
    } catch (_) {
      return null;
    }
  }
}

/// One queued render: [priority] 0 = visible page, 1 = neighbour / thumb.
class _QueuedRender {
  _QueuedRender(this.priority, this.seq, this.run);

  int priority;
  final int seq;
  final Future<void> Function() run;
}

/// Riverpod provider for the singleton [BitmapCache].
final bitmapCacheProvider = Provider<BitmapCache>((ref) {
  return BitmapCache(ref.read(readerRepositoryProvider));
});
