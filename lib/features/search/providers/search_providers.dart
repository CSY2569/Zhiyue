import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/search_repository.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// A search hit the user tapped: jump the reader to [page] (0-indexed) of
/// [bookId] and highlight every occurrence of [query] on that page.
/// Set by the search page before navigating; consumed by the reader for
/// the jump and kept for the in-page highlight until the next search
/// (or Esc).
class SearchHitTarget {
  const SearchHitTarget({
    required this.bookId,
    required this.page,
    required this.query,
  });

  final int bookId;
  final int page; // 0-indexed
  final String query;
}

/// The pending / active in-page hit highlight target (M6, 3.5.3).
final searchHitProvider =
    StateProvider<SearchHitTarget?>((ref) => null);

/// Per-book search-index status ("missing" | "building" | "ready"),
/// polled while any book is building so the library grid badge and the
/// search page stay live.
class SearchIndexStatusNotifier extends Notifier<Map<int, String>> {
  Timer? _poll;

  @override
  Map<int, String> build() {
    ref.onDispose(() => _poll?.cancel());
    return {};
  }

  /// Refresh the status of every PDF book; also triggers background builds
  /// for books with no index yet (pre-build on app start / import, 3.5.1).
  /// Books with a known non-missing status are kept without a round-trip:
  /// the library rebuilds this notifier on every book mutation, and only
  /// new / still-missing books need a fresh query.
  Future<void> refresh() async {
    final books = ref.read(libraryBooksProvider).valueOrNull ??
        const <Book>[];
    final repo = ref.read(searchRepositoryProvider);
    final known = state;
    final statuses = <int, String>{};
    var building = false;
    for (final b in books.where((b) => b.fileType == BookType.pdf)) {
      final prev = known[b.id];
      final status = (prev != null && prev != 'missing')
          ? prev
          : await repo.indexStatus(b.id);
      statuses[b.id] = status;
      if (status == 'missing') {
        await repo.ensureBookIndex(b.id);
      }
      if (status == 'building') building = true;
    }
    state = statuses;
    if (building) _startPoll();
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final repo = ref.read(searchRepositoryProvider);
      final statuses = <int, String>{};
      var building = false;
      for (final id in state.keys.toList()) {
        final s = await repo.indexStatus(id);
        statuses[id] = s;
        if (s == 'building') building = true;
      }
      state = statuses;
      if (!building) {
        _poll?.cancel();
        _poll = null;
      }
    });
  }
}

/// Index status per PDF book id (drives the "索引中" badge).
final searchIndexStatusProvider =
    NotifierProvider<SearchIndexStatusNotifier, Map<int, String>>(
  SearchIndexStatusNotifier.new,
);
