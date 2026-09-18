import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/translate.dart';

/// Wrapper around the FRB bilingual-reading bindings (M7).
///
/// The built-in per-page pipeline was retired in favor of the downloadable
/// BabelDOC engine; this repository now carries the engine-independent
/// surface (config KV, glossary, in-flight registry, artifact cleanup).
/// Engine install/status methods arrive with the engine integration.
class TranslationRepository {
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

  /// Deletes a book's translated artifacts (the produced PDFs).
  Future<int> clearTranslationArtifacts(int bookId) =>
      rust.clearTranslationArtifacts(bookId: bookId);

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
}

/// Riverpod provider for the singleton [TranslationRepository].
final translationRepositoryProvider =
    Provider<TranslationRepository>((ref) => TranslationRepository());