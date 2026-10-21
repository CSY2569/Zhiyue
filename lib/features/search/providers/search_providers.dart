import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
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
final searchHitProvider = StateProvider<SearchHitTarget?>((ref) => null);

/// Per-book search-index status ("missing" | "building" | "ready"),
/// polled while any book is building so the library grid badge and the
/// search page stay live.
class SearchIndexStatusNotifier extends Notifier<Map<int, String>> {
  Timer? _poll;
  bool _refreshing = false;
  bool _refreshQueued = false;
  bool _disposed = false;

  @override
  Map<int, String> build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _poll?.cancel();
      _poll = null;
    });
    // Refresh whenever the book list changes (startup, import, delete)
    // instead of from a widget's build method -- the latter re-ran on every
    // library rebuild, issuing one FFI round-trip per PDF each time.
    ref.listen(libraryBooksProvider, (prev, next) {
      refresh();
    });
    // Initial pass once the provider is built (post-build: no state writes
    // during build).
    Future.microtask(refresh);
    return {};
  }

  /// Refresh the status of every PDF book; also triggers background builds
  /// for books with no index yet (pre-build on app start / import, 3.5.1).
  /// Books with a known non-missing status are kept without a round-trip, and
  /// the status queries run concurrently -- each is an independent DB read
  /// serialized by the Rust DB mutex, so awaiting them one by one only added
  /// latency. A call arriving mid-refresh is coalesced into one more pass so
  /// a book list change during the query is still picked up.
  Future<void> refresh() async {
    if (_disposed) return;
    if (_refreshing) {
      _refreshQueued = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshQueued = false;
        await _refreshOnce();
      } while (_refreshQueued);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce() async {
    try {
      final books =
          ref.read(libraryBooksProvider).valueOrNull ?? const <Book>[];
      final repo = ref.read(searchRepositoryProvider);
      final known = state;
      final ids = [
        for (final b in books)
          if (b.fileType == BookType.pdf) b.id,
      ];
      final statuses = <int, String>{};
      final toQuery = <int>[];
      for (final id in ids) {
        final prev = known[id];
        if (prev != null && prev != 'missing') {
          statuses[id] = prev;
        } else {
          toQuery.add(id);
        }
      }
      final queried = await Future.wait([
        for (final id in toQuery) repo.indexStatus(id),
      ]);
      if (_disposed) return;
      for (var i = 0; i < toQuery.length; i++) {
        statuses[toQuery[i]] = queried[i];
      }
      // Fire-and-forget: the Rust side spawns one build thread per book and
      // dedups re-entry; awaiting them would serialize independent builds.
      for (final entry in statuses.entries) {
        if (entry.value == 'missing') {
          repo.ensureBookIndex(entry.key).ignore();
        }
      }
      final next = {for (final id in ids) id: statuses[id] ?? 'missing'};
      if (!mapEquals(state, next)) state = next;
      if (next.containsValue('building')) {
        _startPoll();
      } else {
        _poll?.cancel();
        _poll = null;
      }
    } catch (_) {
      // Rust core unavailable (widget tests) or a transient DB error: keep
      // the known statuses; the next book-list change retries.
    }
  }

  void _startPoll() {
    if (_disposed || _poll != null) return;
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final repo = ref.read(searchRepositoryProvider);
        final ids = state.keys.toList();
        final queried = await Future.wait([
          for (final id in ids) repo.indexStatus(id),
        ]);
        if (_disposed) return;
        final next = {for (var i = 0; i < ids.length; i++) ids[i]: queried[i]};
        if (!mapEquals(state, next)) state = next;
        if (!next.containsValue('building')) {
          _poll?.cancel();
          _poll = null;
        }
      } catch (_) {
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
