import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/translate.dart';

/// Wrapper around the FRB bilingual-reading bindings (M7, plan §9).
///
/// The only place the translation UI touches `lib/src/rust/*` directly
/// (ARCHITECTURE §1). Streaming page translation returns a
/// `Stream<TranslationProgressEvent>`; cancelling the subscription stops the
/// work on the Rust side.
class TranslationRepository {
  /// Paragraphs of one page (1-indexed) for inspection.
  Future<rust.ExtractParagraphsResult> extractPageParagraphs(
    int bookId,
    int page,
  ) =>
      rust.extractPageParagraphs(bookId: bookId, page: page);

  /// Translates one page, streaming progress. [force] re-extracts and
  /// overwrites the cache even on a hit.
  Stream<TranslationProgressEvent> translatePage({
    required int bookId,
    required int page,
    bool force = false,
  }) =>
      rust.translatePage(bookId: bookId, page: page, force: force);

  /// The cached translation of a page (null when untranslated). Refreshes
  /// the LRU access time on the Rust side.
  Future<rust.PageTranslationResult> getPageTranslation(
    int bookId,
    int page,
  ) =>
      rust.getPageTranslation(bookId: bookId, page: page);

  /// Whole-book progress (translated vs total pages) for the resume check.
  Future<rust.TranslationOverviewResult> getTranslationOverview(int bookId) =>
      rust.getTranslationOverview(bookId: bookId);

  /// Pages of [bookId] with a CURRENT cached translation (stale rows filtered
  /// by the core). One batched read the queue seeds its work list from.
  Future<Set<int>> getTranslatedPages(int bookId) async =>
      (await rust.getTranslatedPages(bookId: bookId))
          .map((p) => p.toInt())
          .toSet();

  /// Deletes every cached translation + artifact of a book.
  Future<int> clearTranslations(int bookId) =>
      rust.clearTranslations(bookId: bookId);

  /// Reads the 对照阅读 config (KV `translation_config`).
  Future<TranslationConfig> getTranslationConfig() =>
      rust.getTranslationConfig();

  /// Persists the 对照阅读 config.
  Future<int> setTranslationConfig(TranslationConfig config) =>
      rust.setTranslationConfig(config: config);

  /// Registers a book as translating (eviction guard).
  Future<int> startBookTranslation(int bookId) =>
      rust.startBookTranslation(bookId: bookId);

  /// Clears the translating registration (finished / cancelled).
  Future<int> cancelTranslation(int bookId) =>
      rust.cancelTranslation(bookId: bookId);

  /// Glossary entries.
  Future<rust.GlossaryResult> listGlossary() => rust.listTranslationGlossary();

  /// Adds a glossary entry; returns the new id (-1 on failure).
  Future<int> addGlossaryEntry({
    required String sourceTerm,
    required String targetTerm,
    String? sourceLang,
    String? targetLang,
  }) =>
      rust.addTranslationGlossary(
        sourceTerm: sourceTerm,
        targetTerm: targetTerm,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );

  /// Removes a glossary entry; returns 1 on success.
  Future<int> deleteGlossaryEntry(int id) =>
      rust.deleteTranslationGlossary(id: id);

  /// Builds the translated PDF on demand, streaming page-granular progress
  /// (plan §6). Completion is observed by the stream ending; read the output
  /// path with [translatedPdfPath].
  Stream<TranslationProgressEvent> buildTranslatedPdf({
    required int bookId,
    required String targetLang,
  }) =>
      rust.buildTranslatedPdf(bookId: bookId, targetLang: targetLang);

  /// Absolute path the translated PDF is (or would be) written to.
  Future<String> translatedPdfPath({
    required int bookId,
    required String targetLang,
  }) =>
      rust.getTranslatedPdfPath(bookId: bookId, targetLang: targetLang);

  /// Renders ONE page's translation to an RGBA bitmap (the pane's page-level
  /// channel): the translation is displayed as a PDF page beside the original.
  /// [hasTranslation] false -> the page is untranslated (show a placeholder).
  Future<rust.TranslatedPageBitmap> renderTranslatedPage({
    required int bookId,
    required int page,
    required String targetLang,
    double dpiScale = 1.0,
  }) =>
      rust.renderTranslatedPage(
        bookId: bookId,
        page: page,
        targetLang: targetLang,
        dpiScale: dpiScale,
      );

  /// Deletes a book's translated artifacts (PDF + formula images). The cache
  /// rows are removed by the FK cascade on book delete.
  Future<int> clearTranslationArtifacts(int bookId) =>
      rust.clearTranslationArtifacts(bookId: bookId);
}

/// Riverpod provider for the singleton [TranslationRepository].
final translationRepositoryProvider =
    Provider<TranslationRepository>((ref) => TranslationRepository());
