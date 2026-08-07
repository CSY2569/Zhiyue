import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// LRU cache of per-page char boxes (selection hit-testing data, FEATURES
/// 4.1.2). Pages are 0-indexed. Evicted least-recently-used first (8 pages
/// covers the visible viewport); cleared when the open book changes.
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

  /// Char boxes for [page], fetching from Rust on first access. Returns an
  /// empty list when the page has no text layer (scanned page; OCR text layer
  /// lands in M5) or when extraction fails.
  Future<List<CharBox>> getOrFetch(int bookId, int page) async {
    final hit = state[page];
    if (hit != null) return hit;

    List<CharBox> boxes;
    try {
      final result =
          await ref.read(readerRepositoryProvider).extractText(bookId, page);
      boxes = result.error == null ? result.boxes : const <CharBox>[];
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
}

/// Char-box cache for the currently open book (auto-clears on book switch).
final charBoxCacheProvider =
    NotifierProvider<CharBoxCache, Map<int, List<CharBox>>>(CharBoxCache.new);
