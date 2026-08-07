import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';

/// Thin wrapper around the FRB-generated Rust bindings for the library
/// (书库) subsystem (FEATURES §2).
///
/// This is the only place in the UI layer that touches `lib/src/rust/*`
/// directly (ARCHITECTURE §1: "Flutter 侧只能通过 data/repositories/ 调用").
/// Upper layers (providers, widgets) depend on this repository, keeping the
/// Rust FFI boundary narrow and the architecture loosely coupled.
class LibraryRepository {
  // --- Books (FEATURES 2.1-2.5) -------------------------------------------

  /// All books, most-recently-opened first (FEATURES 2.3).
  /// Returns an empty list on error so the UI can show the empty-state guide.
  Future<List<Book>> listBooks() async {
    try {
      return await rust.listBooks();
    } catch (_) {
      return [];
    }
  }

  /// Fetch a single book by id. Returns null if not found.
  Future<Book?> getBook(int id) => rust.getBook(id: id);

  /// Import a single file (FEATURES 2.1). De-dup by `original_path` happens
  /// in Rust; the result distinguishes new imports from existing records.
  Future<rust.ImportResult> importBook(String path) =>
      rust.importBook(path: path);

  /// Delete a book and cascade-clean its children (FEATURES 2.4).
  /// Returns 1 on success, 0 if the book was not found.
  Future<int> deleteBook(int id) => rust.deleteBook(id: id);

  /// Toggle the favorite flag (FEATURES 2.5). Returns the updated book, or
  /// null if the id was not found.
  Future<Book?> toggleFavorite(int id) => rust.toggleFavorite(id: id);

  /// Stamp `last_opened_at` to now (FEATURES 2.3).
  Future<int> touchLastOpened(int id) => rust.touchLastOpened(id: id);

  /// Assign or clear a book's category (FEATURES 2.8).
  Future<int> assignCategory(int bookId, int? categoryId) =>
      rust.assignCategory(bookId: bookId, categoryId: categoryId);

  // --- Categories (FEATURES 2.8) ------------------------------------------

  Future<List<Category>> listCategories() async {
    try {
      return await rust.listCategories();
    } catch (_) {
      return [];
    }
  }

  /// Create a category. Returns null if the name is already taken.
  Future<Category?> createCategory(String name) =>
      rust.createCategory(name: name);

  Future<int> renameCategory(int id, String name) =>
      rust.renameCategory(id: id, name: name);

  Future<int> deleteCategory(int id) => rust.deleteCategory(id: id);
}

/// Riverpod provider for the singleton [LibraryRepository].
final libraryRepositoryProvider = Provider<LibraryRepository>((ref) {
  return LibraryRepository();
});
