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

  /// Requests in flight, keyed by page (the selection layer and any other
  /// consumer preload the same page on mount).
  final _inflight = <int, Future<List<CharBox>>>{};

  /// Bumped on every rebuild. A fetch that started before a revision change
  /// must not write its boxes into the rebuilt (empty) map -- they describe
  /// the previous translation artifact.
  int _generation = 0;

  @override
  Map<int, List<CharBox>> build() {
    // The revision identity (book id + artifact revision) is the cache's
    // lifetime: any change rebuilds the notifier with an empty map.
    ref.watch(translationRevisionProvider);
    _generation++;
    _inflight.clear();
    return {};
  }

  /// Char boxes for the translated [page] of [bookId] (0-indexed), fetching
  /// from Rust on first access. Empty list = no translation / no text.
  Future<List<CharBox>> getOrFetch(int bookId, int page) {
    final hit = state[page];
    if (hit != null) return Future.value(hit);
    final pending = _inflight[page];
    if (pending != null) return pending;
    final generation = _generation;
    final future = _fetch(bookId, page, generation);
    _inflight[page] = future;
    future.whenComplete(() {
      if (identical(_inflight[page], future)) _inflight.remove(page);
    });
    return future;
  }

  Future<List<CharBox>> _fetch(int bookId, int page, int generation) async {
    List<CharBox> boxes;
    try {
      final result = await ref
          .read(translationRepositoryProvider)
          .extractTranslatedText(bookId, page);
      boxes = result.error == null ? result.boxes : const <CharBox>[];
    } catch (_) {
      boxes = const <CharBox>[];
    }

    if (generation != _generation) return boxes;
    state = lruTouch(state, page, boxes, _maxPages);
    return boxes;
  }
}

/// Translated-char-box cache for the open book (auto-clears when the
/// translation artifact changes).
final translatedCharBoxCacheProvider =
    NotifierProvider<TranslatedCharBoxCache, Map<int, List<CharBox>>>(
  TranslatedCharBoxCache.new,
);
