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

/// Shared reload pattern for the library's async lists.
///
/// Keeps the current data on screen while re-fetching: flipping to
/// [AsyncValue.loading] used to replace the whole book grid with a spinner on
/// every mutation (import / delete / favorite batch), which unmounted every
/// card and forced all covers to decode again. The previous list stays
/// visible until the refreshed one lands; a first load still shows the
/// spinner because there is no data to keep.
mixin Reloadable<T> on AsyncNotifier<T> {
  Future<void> reload(Future<T> Function() load) async {
    if (!state.hasValue) state = const AsyncValue.loading();
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
  Future<List<Book>> build() async {
    final repo = ref.read(libraryRepositoryProvider);
    // Heal covers whose file was lost (FEATURES 2.6) before listing, so the
    // grid shows the restored image without the user opening each book. A
    // no-op (one existence check per PDF) when every cover is present.
    try {
      await repo.repairCovers();
    } catch (_) {
      // Repair is best-effort; listing must still succeed.
    }
    return repo.listBooks();
  }

  /// Force a full reload from the DB.
  ///
  /// Cover repair is deliberately NOT repeated here: it lists every book and
  /// stats one cover file per PDF in Rust, and this refresh runs after every
  /// mutation (favorite toggle, category move, delete, open). Mutations never
  /// delete cover files, so the once-per-provider-lifetime repair in [build]
  /// is enough and a tap no longer costs N filesystem checks.
  Future<void> refresh() =>
      reload(() => ref.read(libraryRepositoryProvider).listBooks());

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

  /// Bulk delete: one refresh at the end instead of one per book (the grid
  /// stays usable while a large selection is removed).
  Future<int> deleteMany(Iterable<int> ids) async {
    final repo = ref.read(libraryRepositoryProvider);
    var deleted = 0;
    for (final id in ids) {
      try {
        await repo.deleteBook(id);
        deleted++;
      } catch (_) {
        // Count only the ones that actually went through.
      }
    }
    await refresh();
    return deleted;
  }

  /// Bulk favorite: sets every selected book to the same state.
  Future<void> setFavoriteMany(
    Iterable<int> ids, {
    required bool favorite,
  }) async {
    final repo = ref.read(libraryRepositoryProvider);
    for (final id in ids) {
      final book = state.valueOrNull?.where((b) => b.id == id).firstOrNull;
      if (book == null) continue;
      if (book.favorite == favorite) continue;
      try {
        await repo.toggleFavorite(id);
      } catch (_) {
        // Best-effort: the refresh below reconciles.
      }
    }
    await refresh();
  }

  /// Bulk category assignment (null = unclassify).
  Future<void> assignCategoryMany(Iterable<int> ids, int? categoryId) async {
    final repo = ref.read(libraryRepositoryProvider);
    for (final id in ids) {
      try {
        await repo.assignCategory(id, categoryId);
      } catch (_) {
        // Best-effort: the refresh below reconciles.
      }
    }
    await refresh();
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
          .map(
            (b) => b.id == bookId
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
                : b,
          )
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

  Future<void> refresh() =>
      reload(() => ref.read(libraryRepositoryProvider).listCategories());

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

  void setSearchQuery(String q) => _replace(searchQuery: q);

  /// Rebuilds the filter, keeping the axes the caller does not change.
  void _replace({
    String? searchQuery,
    LibraryView? view,
    int? categoryId,
    bool clearCategory = false,
    LibraryType? type,
  }) {
    state = LibraryFilter(
      searchQuery: searchQuery ?? state.searchQuery,
      view: view ?? state.view,
      categoryId: clearCategory ? null : (categoryId ?? state.categoryId),
      type: type ?? state.type,
    );
  }

  /// 全部: no view filter (search / type still apply).
  void showAll() => _replace(view: LibraryView.all, clearCategory: true);

  /// 最近使用: books with a saved open timestamp (the list is already
  /// ordered most-recent-first by the repository).
  void showRecent() =>
      _replace(view: LibraryView.recent, clearCategory: true);

  /// 收藏: every favorite, whatever its type or folder.
  void showFavorites() =>
      _replace(view: LibraryView.favorite, clearCategory: true);

  /// Select a category (the only active view). `null` falls back to 全部.
  void setCategory(int? categoryId) => categoryId == null
      ? showAll()
      : _replace(view: LibraryView.category, categoryId: categoryId);

  /// File-type filter (the shelf's top bar). Independent of the rail's view,
  /// so 「收藏 + PDF」 works.
  void setType(LibraryType type) => _replace(type: type);
}

/// Derived provider: the book list after applying the current filter
/// (FEATURES 2.7). Recomputes whenever books or the filter change.
/// Last-read page per book, for the shelf's progress line.
///
/// Watches the book list, so importing / deleting / reopening a book (which
/// refreshes that list) also refreshes the progress map.
final libraryProgressProvider = FutureProvider<Map<int, int>>((ref) async {
  final books = await ref.watch(libraryBooksProvider.future);
  if (books.isEmpty) return const {};
  return ref.read(libraryRepositoryProvider).listReadingProgress();
});

final filteredBooksProvider = Provider<List<Book>>((ref) {
  final books = ref.watch(libraryBooksProvider).valueOrNull ?? [];
  final filter = ref.watch(libraryFilterProvider);
  if (filter.isClear) return books;

  final query = filter.searchQuery.toLowerCase();
  return books.where((b) {
    if (query.isNotEmpty && !b.title.toLowerCase().contains(query)) {
      return false;
    }
    // Two independent axes: the rail's view (one at a time) and the top
    // bar's file type. Search stacks on top of both.
    final matchesView = switch (filter.view) {
      LibraryView.all => true,
      // Recently opened: anything with a saved open timestamp. The list is
      // already ordered most-recent-first by the repository.
      LibraryView.recent => b.lastOpenedAt != null,
      LibraryView.favorite => b.favorite,
      LibraryView.category => b.categoryId == filter.categoryId,
    };
    final matchesType = switch (filter.type) {
      LibraryType.all => true,
      LibraryType.pdf => b.fileType == BookType.pdf,
      LibraryType.image => b.fileType == BookType.image,
    };
    return matchesView && matchesType;
  }).toList();
});
