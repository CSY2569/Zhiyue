import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/translate.dart';

/// Wrapper around the Android text-level translation FFI (v1 bilingual).
///
/// Mirrors [TranslationRepository]'s role for the RetainPDF engine: the UI
/// never imports `lib/src/rust/api.dart` directly for this feature.
class TextTranslationRepository {
  /// Extracted blocks of one page (no network).
  Future<PageTextBlocks> getPageBlocks(int bookId, int page) =>
      rust.getPageTextBlocks(bookId: bookId, page: page);

  /// Cached translation of one page, or null when absent/stale.
  Future<PageTextTranslation?> getCached(
    int bookId,
    int page,
    String targetLang,
  ) =>
      rust.getPageTextTranslation(
        bookId: bookId,
        page: page,
        targetLang: targetLang,
      );

  /// Translates one page (cache first unless [force]).
  Future<PageTextTranslation> translatePage({
    required int bookId,
    required int page,
    required String targetLang,
    bool force = false,
  }) =>
      rust.translatePageText(
        bookId: bookId,
        page: page,
        targetLang: targetLang,
        force: force,
      );

  /// Cancels the in-flight page translation.
  Future<int> cancel() => rust.cancelPageTextTranslation();

  /// Deletes a book's cached text translations.
  Future<int> clearBook(int bookId) =>
      rust.clearBookTextTranslation(bookId: bookId);

  /// Pages already translated in this book/language.
  Future<int> translatedPageCount(int bookId, String targetLang) =>
      rust.countTextTranslatedPages(bookId: bookId, targetLang: targetLang);
}

final textTranslationRepositoryProvider =
    Provider<TextTranslationRepository>((ref) => TextTranslationRepository());
