import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/src/rust/models/book.dart';

// =============================================================================
// Books
// =============================================================================

/// Aggregate result of an import batch, surfaced to the UI for a SnackBar.
class ImportSummary {
  final int imported;
  final int alreadyExisted;
  final int failed;

  const ImportSummary({
    required this.imported,
    required this.alreadyExisted,
    required this.failed,
  });
}

/// Shared reload pattern for the library's async lists: flip to loading,
/// then re-fetch (AsyncValue.guard keeps errors in the state).
mixin Reloadable<T> on AsyncNotifier<T> {
  Future<void> reload(Future<T> Function() load) async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(load);
  }
}

/// Async list of all books in the library (FEATURES 2.2).
///
/// Mutations (import / delete / favorite / classify) update the DB via the
/// repository and then refresh this provider so the grid stays in sync.
class LibraryBooksNotifier extends AsyncNotifier<List<Book>>
    with Reloadable<List<Book>> {
  @override
  Future<List<Book>> build() {
    return ref.read(libraryRepositoryProvider).listBooks();
  }

  /// Force a full reload from the DB.
  Future<void> refresh() => reload(
        () => ref.read(libraryRepositoryProvider).listBooks(),
      );

  /// Import a batch of files (FEATURES 2.1). Returns a summary so the caller
  /// can show a SnackBar (e.g. "导入 2 本，已存在 1 本").
  Future<ImportSummary> importFiles(List<String> paths) async {
    final repo = ref.read(libraryRepositoryProvider);
    int imported = 0, existed = 0, failed = 0;
    for (final path in paths) {
      try {
        final r = await repo.importBook(path);
        if (r.error != null) {
          failed++;
        } else if (r.alreadyExisted) {
          existed++;
        } else {
          imported++;
        }
      } catch (_) {
        failed++;
      }
    }
    await refresh();
    return ImportSummary(
      imported: imported,
      alreadyExisted: existed,
      failed: failed,
    );
  }

  /// Delete a book (FEATURES 2.4). Optimistically removes it from the local
  /// list; the DB cascades to progress / annotations / OCR cache.
  Future<void> deleteBook(int id) async {
    final repo = ref.read(libraryRepositoryProvider);
    await repo.deleteBook(id);
    state = state.whenData((books) => books.where((b) => b.id != id).toList());
  }

  /// Toggle the favorite flag (FEATURES 2.5). Updates the local list with the
  /// returned book so the star flips immediately.
  Future<void> toggleFavorite(int id) async {
    final repo = ref.read(libraryRepositoryProvider);
    final updated = await repo.toggleFavorite(id);
    if (updated != null) {
      state = state.whenData(
        (books) => books.map((b) => b.id == id ? updated : b).toList(),
      );
    }
  }

  /// Record that a book was opened (FEATURES 2.3: recent-open sort). Reloads
  /// the list so the most-recently-opened ordering is reflected on return.
  Future<void> touchLastOpened(int id) async {
    final repo = ref.read(libraryRepositoryProvider);
    await repo.touchLastOpened(id);
    await refresh();
  }

  /// Assign a book to a category, or unclassify it (FEATURES 2.8).
  Future<void> assignCategory(int bookId, int? categoryId) async {
    final repo = ref.read(libraryRepositoryProvider);
    await repo.assignCategory(bookId, categoryId);
    state = state.whenData(
      (books) => books
          .map((b) => b.id == bookId
              ? Book(
                  id: b.id,
                  title: b.title,
                  originalPath: b.originalPath,
                  storedPath: b.storedPath,
                  fileType: b.fileType,
                  pageCount: b.pageCount,
                  coverPath: b.coverPath,
                  favorite: b.favorite,
                  categoryId: categoryId,
                  lastOpenedAt: b.lastOpenedAt,
                  importedAt: b.importedAt,
                )
              : b)
          .toList(),
    );
  }
}

final libraryBooksProvider =
    AsyncNotifierProvider<LibraryBooksNotifier, List<Book>>(
  LibraryBooksNotifier.new,
);

// =============================================================================
// Categories
// =============================================================================

/// Async list of user-defined categories (FEATURES 2.8).
class CategoriesNotifier extends AsyncNotifier<List<Category>>
    with Reloadable<List<Category>> {
  @override
  Future<List<Category>> build() {
    return ref.read(libraryRepositoryProvider).listCategories();
  }

  Future<void> refresh() => reload(
        () => ref.read(libraryRepositoryProvider).listCategories(),
      );

  /// Create a new category. Returns the created category, or null if the name
  /// was already taken.
  Future<Category?> create(String name) async {
    final repo = ref.read(libraryRepositoryProvider);
    final cat = await repo.createCategory(name);
    if (cat != null) {
      await refresh();
    }
    return cat;
  }

  Future<void> rename(int id, String name) async {
    final repo = ref.read(libraryRepositoryProvider);
    await repo.renameCategory(id, name);
    await refresh();
  }

  /// Delete a category. Books referencing it fall back to unclassified; we
  /// refresh the books provider so the grid reflects the new `category_id`.
  Future<void> delete(int id) async {
    final repo = ref.read(libraryRepositoryProvider);
    await repo.deleteCategory(id);
    await refresh();
    // Books' category_id is now NULL; reload the book list.
    ref.invalidate(libraryBooksProvider);
  }
}

final categoriesProvider =
    AsyncNotifierProvider<CategoriesNotifier, List<Category>>(
  CategoriesNotifier.new,
);

// =============================================================================
// Filter + filtered books
// =============================================================================

/// Synchronous filter state for the library (FEATURES 2.7).
final libraryFilterProvider =
    StateNotifierProvider<LibraryFilterNotifier, LibraryFilter>(
  (ref) => LibraryFilterNotifier(),
);

class LibraryFilterNotifier extends StateNotifier<LibraryFilter> {
  LibraryFilterNotifier() : super(const LibraryFilter());

  void setSearchQuery(String q) => state = state.copyWith(searchQuery: q);

  /// 全部: no view filter (search still applies).
  void showAll() =>
      state = LibraryFilter(searchQuery: state.searchQuery);

  /// PDF: every PDF in the library, regardless of category / favorites.
  void showPdf() =>
      state = LibraryFilter(searchQuery: state.searchQuery, view: LibraryView.pdf);

  /// 图片: every image book, regardless of category / favorites.
  void showImage() => state =
      LibraryFilter(searchQuery: state.searchQuery, view: LibraryView.image);

  /// 收藏: every favorite, regardless of category / type.
  void showFavorites() => state =
      LibraryFilter(searchQuery: state.searchQuery, view: LibraryView.favorite);

  /// Select a category (the only active view). `null` falls back to 全部.
  void setCategory(int? categoryId) => state = categoryId == null
      ? LibraryFilter(searchQuery: state.searchQuery)
      : LibraryFilter(
          searchQuery: state.searchQuery,
          view: LibraryView.category,
          categoryId: categoryId,
        );
}

/// Derived provider: the book list after applying the current filter
/// (FEATURES 2.7). Recomputes whenever books or the filter change.
final filteredBooksProvider = Provider<List<Book>>((ref) {
  final books = ref.watch(libraryBooksProvider).valueOrNull ?? [];
  final filter = ref.watch(libraryFilterProvider);
  if (filter.isClear) return books;

  final query = filter.searchQuery.toLowerCase();
  return books.where((b) {
    if (query.isNotEmpty && !b.title.toLowerCase().contains(query)) {
      return false;
    }
    // Exactly one primary view is active at a time (mutually exclusive rail
    // entries); search is the only stacking filter.
    return switch (filter.view) {
      LibraryView.all => true,
      LibraryView.pdf => b.fileType == BookType.pdf,
      LibraryView.image => b.fileType == BookType.image,
      LibraryView.favorite => b.favorite,
      LibraryView.category => b.categoryId == filter.categoryId,
    };
  }).toList();
});
