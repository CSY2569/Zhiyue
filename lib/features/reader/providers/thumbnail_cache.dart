import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/image_decoder.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';

/// LRU cache of decoded page thumbnails (FEATURES 3.4.1).
///
/// Without this, every sidebar open / scroll re-rendered pages through
/// pdfium (tens of ms each, serialized by the document mutex), which made
/// the rail feel slow. Keyed by page; cleared when the open book changes.
/// In-flight requests are de-duplicated so fast scrolling renders each page
/// at most once.
class ThumbnailCache extends Notifier<Map<int, ui.Image>> {
  static const int _maxEntries = 120;

  // Pages currently being rendered (de-dup: one render per page).
  final _inflight = <int, Future<ui.Image?>>{};

  @override
  Map<int, ui.Image> build() {
    // Switching books invalidates thumbnails of the previous book.
    ref.listen(viewerProvider.select((s) => s.book?.id), (prev, next) {
      if (prev != next) {
        _inflight.clear();
        state = {};
      }
    });
    return {};
  }

  /// The decoded thumbnail for [page], rendering it on first access. Returns
  /// null when rendering failed or the page has no content.
  Future<ui.Image?> getOrFetch(int bookId, int page) async {
    final hit = state[page];
    if (hit != null) return hit;
    final inFlight = _inflight[page];
    if (inFlight != null) return inFlight;
    final future = _fetch(bookId, page);
    _inflight[page] = future;
    future.whenComplete(() => _inflight.remove(page));
    return future;
  }

  Future<ui.Image?> _fetch(int bookId, int page) async {
    try {
      final result =
          await ref.read(readerRepositoryProvider).renderThumbnail(bookId, page, 150);
      if (result.error != null || result.rgba.isEmpty) return null;
      final image =
          await decodeRgbaImage(result.width, result.height, result.rgba);
      if (image == null) return null;
      // Re-insert at the tail to keep insertion order = LRU order.
      final next = Map<int, ui.Image>.from(state)
        ..remove(page)
        ..[page] = image;
      while (next.length > _maxEntries) {
        next.remove(next.keys.first);
      }
      state = next;
      return image;
    } catch (_) {
      return null;
    }
  }
}

/// Decoded thumbnails of the open book (auto-clears on book switch).
final thumbnailCacheProvider =
    NotifierProvider<ThumbnailCache, Map<int, ui.Image>>(ThumbnailCache.new);
