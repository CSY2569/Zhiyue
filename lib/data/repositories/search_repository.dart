import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rbwa/src/rust/api.dart' as rust;

/// Full-text search over the library's indexed pages (FEATURES 3.5, M6).
///
/// The only place the search UI touches `lib/src/rust/*` directly
/// (ARCHITECTURE §1). Index maintenance is asynchronous: [ensureBookIndex]
/// fires a background build; [indexStatus] reports missing / building /
/// ready.
class SearchRepository {
  /// Library-wide search; hits ordered by book then page.
  Future<rust.SearchResult> searchBooks(String query, {int? limit}) =>
      rust.searchBooks(query: query, limit: limit);

  /// Trigger a background index build for a book (no-op when already
  /// indexed or building).
  Future<void> ensureBookIndex(int bookId) =>
      rust.ensureBookIndex(bookId: bookId);

  /// "missing" | "building" | "ready".
  Future<String> indexStatus(int bookId) =>
      rust.searchIndexStatus(bookId: bookId);

}

final searchRepositoryProvider =
    Provider<SearchRepository>((ref) => SearchRepository());
