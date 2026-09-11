import 'dart:typed_data';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/src/rust/api.dart'
    show
        ExtractParagraphsResult,
        GlossaryResult,
        PageTranslationResult,
        TranslatedPageBitmap,
        TranslationOverviewResult;
import 'package:rbwa/src/rust/models/translate.dart';

/// Fake translation repository for widget tests: no Rust, in-memory cache
/// keyed by page, streaming events driven by a fixed script.
class FakeTranslationRepo extends TranslationRepository {
  FakeTranslationRepo({
    this.config = const TranslationConfig(
      provider: TranslationProviderKind.reuseAi,
      baseUrl: null,
      apiKey: null,
      model: null,
      sourceLang: 'auto',
      mode: TranslationMode.withProgress,
      backgroundBehavior: TranslationBackgroundBehavior.ask,
      autoOcr: true,
      concurrency: 2,
      cacheLimitMb: 2048,
    ),
  });

  TranslationConfig config;
  TranslationConfig? saved;

  /// page -> cached translation.
  final cache = <int, PageTranslation>{};
  final translateCalls = <(int, int, bool)>[];
  final cleared = <int>[];
  final started = <int>[];
  final cancelled = <int>[];

  /// When true, [translatePage] streams an error instead of a result.
  bool failTranslate = false;

  /// Whether [renderTranslatedPage] reports a translation for the page.
  /// A 2x2 opaque bitmap is returned so the provider decodes a real image.
  bool hasTranslation = true;

  @override
  Future<TranslationConfig> getTranslationConfig() async => config;

  @override
  Future<int> setTranslationConfig(TranslationConfig config) async {
    this.config = config;
    saved = config;
    return 1;
  }

  @override
  Future<TranslatedPageBitmap> renderTranslatedPage({
    required int bookId,
    required int page,
    required String targetLang,
    double dpiScale = 1.0,
  }) async {
    if (!hasTranslation) {
      return TranslatedPageBitmap(
        width: 0,
        height: 0,
        rgba: Uint8List(0),
        hasTranslation: false,
        error: null,
      );
    }
    // 2x2 RGBA, all opaque white.
    final rgba = Uint8List.fromList(List.filled(2 * 2 * 4, 255));
    return TranslatedPageBitmap(
      width: 2,
      height: 2,
      rgba: rgba,
      hasTranslation: true,
      error: null,
    );
  }

  @override
  Future<PageTranslationResult> getPageTranslation(int bookId, int page) async {
    return PageTranslationResult(translation: cache[page], error: null);
  }

  @override
  Stream<TranslationProgressEvent> translatePage({
    required int bookId,
    required int page,
    bool force = false,
  }) {
    translateCalls.add((bookId, page, force));
    if (failTranslate) {
      return Stream.error(Exception('未配置翻译服务'));
    }
    if (cache[page] == null || force) {
      cache[page] = PageTranslation(
        page: page,
        targetLang: '中文',
        provider: 'reuse_ai',
        sourceHash: 'h',
        paragraphs: [
          TranslatedParagraph(
            source: 'Hello world',
            translated: '你好世界',
            kind: ParagraphKind.text,
            status: ParagraphStatus.done,
            confidence: 1.0,
            formulaRegions: const [],
          ),
        ],
        coverage: 1.0,
      );
    }
    return Stream.fromIterable([
      TranslationProgressEvent(
        page: page,
        doneParagraphs: 0,
        totalParagraphs: 1,
        coverage: 0.0,
        finished: false,
        error: null,
      ),
      TranslationProgressEvent(
        page: page,
        doneParagraphs: 1,
        totalParagraphs: 1,
        coverage: 1.0,
        finished: true,
        error: null,
      ),
    ]);
  }

  @override
  Future<TranslationOverviewResult> getTranslationOverview(int bookId) async =>
      TranslationOverviewResult(
        totalPages: 10,
        translatedPages: cache.length,
        targetLang: '中文',
        error: null,
      );

  @override
  Future<int> clearTranslations(int bookId) async {
    cleared.add(bookId);
    cache.clear();
    return 1;
  }

  @override
  Future<int> startBookTranslation(int bookId) async {
    started.add(bookId);
    return 1;
  }

  @override
  Future<int> cancelTranslation(int bookId) async {
    cancelled.add(bookId);
    return 1;
  }

  @override
  Future<ExtractParagraphsResult> extractPageParagraphs(int bookId, int page) async =>
      const ExtractParagraphsResult(paragraphs: [], error: null);

  @override
  Future<GlossaryResult> listGlossary() async =>
      const GlossaryResult(entries: [], error: null);

  final glossary = <GlossaryEntry>[];
  int _nextGlossaryId = 1;

  @override
  Future<int> addGlossaryEntry({
    required String sourceTerm,
    required String targetTerm,
    String? sourceLang,
    String? targetLang,
  }) async {
    final id = _nextGlossaryId++;
    glossary.add(GlossaryEntry(
      id: id,
      sourceTerm: sourceTerm,
      targetTerm: targetTerm,
      sourceLang: sourceLang,
      targetLang: targetLang,
    ));
    return id;
  }

  @override
  Future<int> deleteGlossaryEntry(int id) async {
    glossary.removeWhere((e) => e.id == id);
    return 1;
  }
}
