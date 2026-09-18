import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/src/rust/api.dart' show GlossaryResult;
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

  // --- engine (BabelDOC) --------------------------------------------------

  /// Current engine status reported by [getEngineStatus].
  EngineStatus engineStatus = const EngineStatus(
    kind: EngineStatusKind.notInstalled,
    phase: '',
    progress: 0,
    version: '',
    sizeBytes: 0,
    error: null,
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