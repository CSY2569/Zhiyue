import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/lru.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/book_translation_provider.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// LRU cache of the TRANSLATED pages' char boxes (selection hit-testing data
/// for the translated pane, FEATURES 7.4). Mirrors [CharBoxCache] but is fed
/// by `extractTranslatedText` and keys on the book; evicted LRU-first (8
/// pages covers the viewport).
///
/// Invalidation: the revision counter bumps whenever a translation artifact
/// appears, changes or is deleted (see `translationRevisionProvider`), so a
/// re-translation drops stale boxes automatically.
class TranslatedCharBoxCache extends Notifier<Map<int, List<CharBox>>> {
  static const int _maxPages = 8;

  @override
  Map<int, List<CharBox>> build() {
    // The revision identity (book id + artifact revision) is the cache's
    // lifetime: any change rebuilds the notifier with an empty map.
    ref.watch(translationRevisionStateProvider);
    return {};
  }

  /// Char boxes for the translated [page] of [bookId] (0-indexed), fetching
  /// from Rust on first access. Empty list = no translation / no text.
  Future<List<CharBox>> getOrFetch(int bookId, int page) async {
    final hit = state[page];
    if (hit != null) return hit;

    List<CharBox> boxes;
    try {
      final result = await ref
          .read(translationRepositoryProvider)
          .extractTranslatedText(bookId, page);
      boxes = result.error == null ? result.boxes : const <CharBox>[];
    } catch (_) {
      boxes = const <CharBox>[];
    }

    state = lruTouch(state, page, boxes, _maxPages);
    return boxes;
  }
}

/// Translated-char-box cache for the open book (auto-clears when the
/// translation artifact changes).
final translatedCharBoxCacheProvider =
    NotifierProvider<TranslatedCharBoxCache, Map<int, List<CharBox>>>(
        TranslatedCharBoxCache.new);

/// A small provider whose value changes whenever the artifact revision does,
/// so [TranslatedCharBoxCache.build] can watch it as its invalidation key.
final translationRevisionStateProvider = Provider<int>((ref) {
  return ref.watch(translationRevisionProvider);
});