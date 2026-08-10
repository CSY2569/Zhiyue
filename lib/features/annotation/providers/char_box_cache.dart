import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  @override
  Map<int, List<CharBox>> build() {
    // Switching books invalidates cached page data.
    ref.listen(viewerProvider.select((s) => s.book?.id), (prev, next) {
      if (prev != next) state = {};
    });
    return {};
  }

  /// Char boxes for [page], fetching from Rust on first access. Pages
  /// without a native text layer fall back to the OCR text layer.
  Future<List<CharBox>> getOrFetch(int bookId, int page) async {
    final hit = state[page];
    if (hit != null) return hit;

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

    // Re-insert at the tail to keep insertion order = LRU order.
    final next = Map<int, List<CharBox>>.from(state)
      ..remove(page)
      ..[page] = boxes;
    while (next.length > _maxPages) {
      next.remove(next.keys.first);
    }
    state = next;
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
            CharBox(
              char: l.text,
              x: l.x,
              y: l.y,
              w: l.w,
              h: l.h,
            ),
      ];
    } catch (_) {
      return const <CharBox>[];
    }
  }
}

/// Char-box cache for the currently open book (auto-clears on book switch).
final charBoxCacheProvider =
    NotifierProvider<CharBoxCache, Map<int, List<CharBox>>>(CharBoxCache.new);
