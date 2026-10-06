import 'package:rbwa/data/repositories/translation_repository.dart';
import 'dart:typed_data';

import 'package:rbwa/src/rust/api.dart'
    show BookTranslationResult, GlossaryResult, TranslatedPageBitmap;
import 'package:rbwa/src/rust/models/translate.dart';

/// Fake translation repository for widget tests: no Rust, in-memory config +
/// glossary + registry bookkeeping. The retired per-page pipeline methods are
/// gone; engine install/status methods arrive with the engine integration.
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

  final started = <int>[];
  final cancelled = <int>[];
  final clearedArtifacts = <int>[];

  final glossary = <GlossaryEntry>[];
  int _nextGlossaryId = 1;

  // --- engine (RetainPDF) -------------------------------------------------

  /// Current engine status reported by [getEngineStatus].
  EngineStatus engineStatus = const EngineStatus(
    kind: EngineStatusKind.notInstalled,
    phase: '',
    progress: 0,
    version: '',
    sizeBytes: 0,
    error: null,
    bundled: false,
  );

  /// Event script streamed by [installEngine]; a final event with
  /// [EngineInstallEvent.finished] ends the stream.
  List<EngineInstallEvent> installScript = const [
    EngineInstallEvent(
        phase: '下载 uv', progress: 0.1, detail: '', finished: false, error: null),
    EngineInstallEvent(
        phase: '完成', progress: 1.0, detail: '', finished: true, error: null),
  ];

  int installCalls = 0;
  int cancelCalls = 0;
  int uninstallCalls = 0;

  @override
  Future<EngineStatus> getEngineStatus() async => engineStatus;

  @override
  Stream<EngineInstallEvent> installEngine() {
    installCalls++;
    return Stream.fromIterable(installScript);
  }

  @override
  Future<int> cancelEngineInstall() async {
    cancelCalls++;
    return 1;
  }

  // --- whole-book translation --------------------------------------------

  /// Artifact reported by [getBookTranslation] (null = not translated yet).
  BookTranslation? bookTranslation;
  bool bookTranslateRunning = false;

  /// Event script streamed by [translateBook].
  List<BookTranslateEvent> translateScript = const [
    BookTranslateEvent(
        phase: '翻译中', detail: 'start to translate', done: false, error: null),
    BookTranslateEvent(phase: '完成', detail: '已翻译', done: true, error: null),
  ];

  int translateCalls = 0;
  int cancelBookCalls = 0;
  int clearBookCalls = 0;

  @override
  Stream<BookTranslateEvent> translateBook(int bookId) {
    translateCalls++;
    return Stream.fromIterable(translateScript);
  }

  @override
  Future<int> cancelBookTranslation() async {
    cancelBookCalls++;
    return 1;
  }

  @override
  Future<BookTranslationResult> getBookTranslation(int bookId) async =>
      BookTranslationResult(
        translation: bookTranslation,
        running: bookTranslateRunning,
      );

  @override
  Future<int> clearBookTranslation(int bookId) async {
    clearBookCalls++;
    bookTranslation = null;
    return 1;
  }

  @override
  Future<TranslatedPageBitmap> renderTranslatedPage({
    required int bookId,
    required int page,
    double dpiScale = 1.0,
  }) async {
    if (bookTranslation == null) {
      return TranslatedPageBitmap(
        width: 0,
        height: 0,
        rgba: Uint8List(0),
        hasTranslation: false,
        error: null,
      );
    }
    // 2x2 opaque white bitmap (decodes on the engine's task runner).
    return TranslatedPageBitmap(
      width: 2,
      height: 2,
      rgba: Uint8List.fromList(List.filled(2 * 2 * 4, 255)),
      hasTranslation: true,
      error: null,
    );
  }

  @override
  Future<int> uninstallEngine() async {
    uninstallCalls++;
    engineStatus = const EngineStatus(
      kind: EngineStatusKind.notInstalled,
      phase: '',
      progress: 0,
      version: '',
      sizeBytes: 0,
      error: null,
      bundled: false,
    );
    return 1;
  }

  @override
  Future<TranslationConfig> getTranslationConfig() async => config;

  @override
  Future<int> setTranslationConfig(TranslationConfig config) async {
    this.config = config;
    saved = config;
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
  Future<int> clearTranslationArtifacts(int bookId) async {
    clearedArtifacts.add(bookId);
    return 1;
  }

  @override
  Future<GlossaryResult> listGlossary() async =>
      GlossaryResult(entries: List.of(glossary), error: null);

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