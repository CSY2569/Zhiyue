import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/lru.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/reader/providers/ocr_helpers.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// LRU cache of per-page char boxes (selection hit-testing data, FEATURES
/// 4.1.2). Pages are 0-indexed. Evicted least-recently-used first (8 pages
/// covers the visible viewport); cleared when the open book changes.
///
/// Scanned pages / image books have no native text layer: the cached OCR
/// result (7.1.3 invisible text layer) is served here instead, so selection
/// works on them too. The OCR cache fills in when a scan succeeds (the scan
/// provider invalidates this cache).
class CharBoxCache extends Notifier<Map<int, List<CharBox>>> {
  static const int _maxPages = 8;

  /// Requests already in flight, keyed by page. Three layers (selection,
  /// low-confidence markers, search hits) ask for the same page on mount;
  /// without this they each fired their own `extractText` round-trip, and a
  /// scanned page paid for three OCR cache lookups.
  final _inflight = <int, Future<List<CharBox>>>{};

  /// Book the cached boxes belong to. An in-flight fetch that finishes after
  /// a book switch must not publish into the new book's map (same page key,
  /// different document -- the selection layer would hit-test against the
  /// wrong geometry).
  int? _bookId;

  @override
  Map<int, List<CharBox>> build() {
    _bookId = ref.read(viewerProvider).book?.id;
    _inflight.clear();
    // Switching books invalidates cached page data.
    ref.listen(viewerProvider.select((s) => s.book?.id), (prev, next) {
      if (prev == next) return;
      _bookId = next;
      _inflight.clear();
      state = {};
    });
    return {};
  }

  /// Char boxes for [page], fetching from Rust on first access. Pages
  /// without a native text layer fall back to the OCR text layer.
  Future<List<CharBox>> getOrFetch(int bookId, int page) {
    final hit = state[page];
    if (hit != null) return Future.value(hit);
    final pending = _inflight[page];
    if (pending != null) return pending;
    final future = _fetch(bookId, page);
    _inflight[page] = future;
    future.whenComplete(() {
      if (identical(_inflight[page], future)) _inflight.remove(page);
    });
    return future;
  }

  Future<List<CharBox>> _fetch(int bookId, int page) async {
    List<CharBox> boxes;
    try {
      final result =
          await ref.read(readerRepositoryProvider).extractText(bookId, page);
      boxes = result.error == null && result.boxes.isNotEmpty
          ? result.boxes
          : await _ocrBoxes(bookId, page);
    } catch (_) {
      boxes = const <CharBox>[];
    }

    // The book changed while we were extracting: return the data to the
    // caller (its widget is going away anyway) but never cache it. A null
    // `_bookId` means the first fetch happens before the viewer reports the
    // book; adopt the caller's id instead of refusing to cache.
    final current = _bookId ??= bookId;
    if (current != bookId) return boxes;
    // Touch in the LRU (re-inserted at the tail).
    state = lruTouch(state, page, boxes, _maxPages);
    return boxes;
  }

  /// OCR invisible text layer (FEATURES 7.1.3): each cached line becomes one
  /// whole-line CharBox (`char` = the full line text, box = the line's
  /// normalized rect). Per-character positions are NOT synthesized here --
  /// the selection layer uses `TextPainter.getPositionForOffset` for precise
  /// in-line character hit-testing (accurate for mixed CJK + Latin + symbols
  /// with kerning). Uses the configured model set (7.1.9) so the layer
  /// matches what the scan produced.
  Future<List<CharBox>> _ocrBoxes(int bookId, int page) async {
    try {
      final ocr = await cachedOcrAnyMode(
        repo: ref.read(readerRepositoryProvider),
        modeResolver: () =>
            configuredOcrMode(ref.read(aiConfigProvider.future)),
        bookId: bookId,
        page: page,
      );
      if (ocr == null) return const [];
      return [
        for (final l in ocr.lines)
          if (l.text.trim().isNotEmpty)
            CharBox(char: l.text, x: l.x, y: l.y, w: l.w, h: l.h),
      ];
    } catch (_) {
      return const <CharBox>[];
    }
  }
}

/// Char-box cache for the currently open book (auto-clears on book switch).
final charBoxCacheProvider =
    NotifierProvider<CharBoxCache, Map<int, List<CharBox>>>(CharBoxCache.new);
