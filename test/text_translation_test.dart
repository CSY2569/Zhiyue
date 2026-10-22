import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/text_translation_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/page_text_translation_provider.dart';
import 'package:rbwa/features/bilingual/widgets/translated_text_column.dart';
import 'package:rbwa/src/rust/models/ai.dart';
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/ai_config_fixture.dart';
import 'helpers/widget_harness.dart';

/// In-memory text-translation repository: no FFI, no network.
class _FakeTextRepo implements TextTranslationRepository {
  _FakeTextRepo({
    this.blocks = const [],
    this.cached,
    this.translation,
    this.error,
  });

  final List<TextBlock> blocks;
  PageTextTranslation? cached;
  PageTextTranslation? translation;
  String? error;

  int translateCalls = 0;
  int forceCalls = 0;
  final List<int> requestedPages = [];

  @override
  Future<PageTextBlocks> getPageBlocks(int bookId, int page) async =>
      PageTextBlocks(
        page: page,
        width: 600,
        height: 800,
        blocks: blocks,
        error: null,
      );

  @override
  Future<PageTextTranslation?> getCached(
    int bookId,
    int page,
    String targetLang,
  ) async =>
      cached;

  @override
  Future<PageTextTranslation> translatePage({
    required int bookId,
    required int page,
    required String targetLang,
    bool force = false,
  }) async {
    translateCalls++;
    if (force) forceCalls++;
    requestedPages.add(page);
    if (error != null) {
      return PageTextTranslation(
        page: page,
        width: 0,
        height: 0,
        targetLang: targetLang,
        model: '',
        blocks: const [],
        cached: false,
        error: error,
      );
    }
    return translation ??
        PageTextTranslation(
          page: page,
          width: 0,
          height: 0,
          targetLang: targetLang,
          model: 'mock',
          blocks: const [],
          cached: false,
          error: error,
        );
  }

  @override
  Future<int> cancel() async => 1;

  @override
  Future<int> clearBook(int bookId) async => 0;

  @override
  Future<int> translatedPageCount(int bookId, String targetLang) async => 0;
}

PageTextTranslation _translation(
  int page, {
  required List<TranslatedTextBlock> blocks,
  bool cached = false,
  String? error,
}) =>
    PageTextTranslation(
      page: page,
      width: 600,
      height: 800,
      targetLang: '中文',
      model: 'mock-model',
      blocks: blocks,
      cached: cached,
      error: error,
    );

TranslatedTextBlock _block(
  int index, {
  String kind = 'text',
  String subType = 'body',
  required String source,
  required String translated,
  TextBlockStatus status = TextBlockStatus.done,
  String? error,
}) =>
    TranslatedTextBlock(
      index: index,
      kind: kind,
      subType: subType,
      x: 0.1,
      y: 0.1 * index,
      w: 0.8,
      h: 0.05,
      sourceText: source,
      translatedText: translated,
      status: status,
      error: error,
    );

void main() {
  group('platform capabilities', () {
    test('desktop uses the RetainPDF engine', () {
      const caps = PlatformCapabilities(
        isMobile: false,
        isAndroid: false,
        bilingualMode: BilingualMode.retainPdf,
      );
      expect(caps.usesRetainEngine, isTrue);
      expect(caps.usesTextTranslation, isFalse);
      expect(PlatformCapabilities.isCompactWidth(699), isTrue);
      expect(PlatformCapabilities.isCompactWidth(700), isFalse);
      expect(PlatformCapabilities.isCompactWidth(1024), isFalse);
    });
  });

  group('page text translation provider', () {
    test('cache hit short-circuits before any LLM call', () async {
      final repo = _FakeTextRepo(
        cached: _translation(
          3,
          blocks: [_block(0, source: 'Hello', translated: '你好')],
          cached: true,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          textTranslationRepositoryProvider.overrideWithValue(repo),
          aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
        ],
      );
      addTearDown(container.dispose);

      // autoDispose: the provider must stay alive for the assertions below.
      final key = (bookId: 1, page: 3);
      final sub = container.listen(pageTextTranslationProvider(key), (_, _) {});
      addTearDown(sub.close);

      final state = await container.read(
        pageTextTranslationProvider(key).future,
      );
      expect(state.translation, isNotNull);
      expect(state.translation!.cached, isTrue);
      expect(repo.translateCalls, 0);
    });

    test('translate stores the result and reports page errors', () async {
      final repo = _FakeTextRepo(
        translation: _translation(
          2,
          blocks: [_block(0, source: 'Hi', translated: '嗨')],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          textTranslationRepositoryProvider.overrideWithValue(repo),
          aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
        ],
      );
      addTearDown(container.dispose);

      final key = (bookId: 1, page: 2);
      final sub = container.listen(pageTextTranslationProvider(key), (_, _) {});
      addTearDown(sub.close);
      await container.read(pageTextTranslationProvider(key).future);
      await container
          .read(pageTextTranslationProvider(key).notifier)
          .translate();

      final state = container.read(pageTextTranslationProvider(key)).value!;
      expect(state.translation!.blocks.single.translatedText, '嗨');
      expect(repo.translateCalls, greaterThanOrEqualTo(1));

      // force=true reaches the repository.
      await container
          .read(pageTextTranslationProvider(key).notifier)
          .translate(force: true);
      expect(repo.forceCalls, 1);
    });

    test('page-level error surfaces and leaves no translation', () async {
      final repo = _FakeTextRepo(error: '请先在「AI 设置」中配置服务');
      final container = ProviderContainer(
        overrides: [
          textTranslationRepositoryProvider.overrideWithValue(repo),
          aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
        ],
      );
      addTearDown(container.dispose);

      final key = (bookId: 1, page: 1);
      final sub = container.listen(pageTextTranslationProvider(key), (_, _) {});
      addTearDown(sub.close);
      await container.read(pageTextTranslationProvider(key).future);
      await container
          .read(pageTextTranslationProvider(key).notifier)
          .translate();

      final state = container.read(pageTextTranslationProvider(key)).value!;
      expect(state.translation, isNull);
      expect(state.error, contains('AI 设置'));
    });
  });

  group('translated text column', () {
    testWidgets('renders blocks, formulas and failed blocks', (tester) async {
      final repo = _FakeTextRepo(
        cached: _translation(
          4,
          blocks: [
            _block(
              0,
              subType: 'heading',
              source: 'Introduction',
              translated: '引言',
            ),
            _block(1, source: 'Hello world', translated: '你好，世界'),
            _block(
              2,
              kind: 'formula',
              subType: 'display_formula',
              source: 'E = mc^2',
              translated: 'E = mc^2',
              status: TextBlockStatus.skipped,
            ),
            _block(
              3,
              source: 'Broken',
              translated: '',
              status: TextBlockStatus.failed,
              error: '模型未返回该段译文',
            ),
          ],
          cached: true,
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textTranslationRepositoryProvider.overrideWithValue(repo),
            aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
            defaultViewer(book: testBook(pageCount: 10)),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: TranslatedTextColumn(bookId: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('引言'), findsOneWidget);
      expect(find.text('你好，世界'), findsOneWidget);
      expect(find.text('E = mc^2'), findsOneWidget);
      expect(find.text('公式'), findsOneWidget);
      expect(find.textContaining('未翻译'), findsOneWidget);
      expect(find.text('已缓存'), findsOneWidget);
    });

    testWidgets('shows the pre-translation prompt with a translate action', (
      tester,
    ) async {
      final repo = _FakeTextRepo(
        blocks: [
          TextBlock(
            index: 0,
            kind: 'text',
            subType: 'body',
            x: 0.1,
            y: 0.1,
            w: 0.8,
            h: 0.05,
            text: 'Some text',
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textTranslationRepositoryProvider.overrideWithValue(repo),
            aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
            defaultViewer(book: testBook(pageCount: 10)),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: TranslatedTextColumn(bookId: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('翻译本页'), findsOneWidget);
      await tester.tap(find.text('翻译本页'));
      await tester.pumpAndSettle();
      expect(repo.translateCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('empty page explains OCR instead of offering translate', (
      tester,
    ) async {
      final repo = _FakeTextRepo(blocks: const []);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            textTranslationRepositoryProvider.overrideWithValue(repo),
            aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
            defaultViewer(book: testBook(pageCount: 10)),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: TranslatedTextColumn(bookId: 1)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('本页没有可翻译的文字'), findsOneWidget);
      expect(find.text('翻译本页'), findsNothing);
    });
  });
}

/// Minimal async AI config with a fixed value (avoids the real repository).
class _FixedAiConfig extends AiConfigNotifier {
  _FixedAiConfig(this.config);

  final AiConfig config;

  @override
  Future<AiConfig> build() async => config;
}
