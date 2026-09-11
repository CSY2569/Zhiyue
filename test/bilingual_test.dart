import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/bilingual_utils.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart';
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_translation_repo.dart';
import 'helpers/widget_harness.dart';

void main() {
  group('panel layout — translated pane width', () {
    test('defaults and clamps use the 280-900 range (plan §1 v4.2)', () {
      expect(const PanelLayout().translatedPaneWidth, 480);
      expect(PanelLayout.minTranslatedPaneWidth, 280);
      expect(PanelLayout.maxTranslatedPaneWidth, 900);
      expect(PanelLayout.minContentWidth, 360);
    });
  });

  group('formula token substitution', () {
    test('replaces MATH_n with the region source text, in order', () {
      final regions = [
        const FormulaRegion(
          rect: NormRect(x: 0, y: 0, w: 0, h: 0),
          imagePath: null,
          sourceText: 'x2 +y',
          placeholder: '',
        ),
        const FormulaRegion(
          rect: NormRect(x: 0, y: 0, w: 0, h: 0),
          imagePath: null,
          sourceText: 'a+b',
          placeholder: '',
        ),
      ];
      expect(
        substituteFormulaTokens('当 ⟨Fabc-MATH_0⟩ 与 ⟨F9x-MATH_1⟩ 都很大', regions),
        '当 x2 +y 与 a+b 都很大',
      );
      expect(
        substituteFormulaTokens('{ ⟨F1-MATH_5⟩ }', regions),
        '{ ⟨F1-MATH_5⟩ }',
      );
      expect(substituteFormulaTokens('纯文本', regions), '纯文本');
    });
  });

  group('translated page image provider', () {
    testWidgets('renders an image when the page has a translation',
        (tester) async {
      final repo = FakeTranslationRepo();
      final container = ProviderContainer(overrides: [
        translationRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      const key = (bookId: 1, page: 2, targetLang: '中文');
      // Decoding pixels runs on the engine's task runner: runAsync lets it
      // complete instead of deadlocking the fake-async zone.
      final img = await tester.runAsync(
        () => container.read(translatedPageImageProvider(key).future),
      );
      expect(img!.hasTranslation, isTrue);
      expect(img.image, isNotNull, reason: 'a bitmap should be decoded');
      expect(img.width, greaterThan(0));
    });

    testWidgets('untranslated page yields hasTranslation=false', (tester) async {
      final repo = FakeTranslationRepo()..hasTranslation = false;
      final container = ProviderContainer(overrides: [
        translationRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      const key = (bookId: 1, page: 9, targetLang: '中文');
      final img = await tester.runAsync(
        () => container.read(translatedPageImageProvider(key).future),
      );
      expect(img!.hasTranslation, isFalse);
      expect(img.image, isNull);
    });

    testWidgets('bumping the revision re-renders the page', (tester) async {
      final repo = FakeTranslationRepo()..hasTranslation = false;
      final container = ProviderContainer(overrides: [
        translationRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      const key = (bookId: 1, page: 3, targetLang: '中文');

      final before = await tester.runAsync(
        () => container.read(translatedPageImageProvider(key).future),
      );
      expect(before!.hasTranslation, isFalse);

      // Simulate the translation finishing, then invalidate.
      repo.hasTranslation = true;
      container.read(translationRevisionProvider.notifier).state++;
      container.invalidate(translatedPageImageProvider(key));

      final after = await tester.runAsync(
        () => container.read(translatedPageImageProvider(key).future),
      );
      expect(after!.hasTranslation, isTrue,
          reason: 'revision bump must surface the new translation');
    });
  });

  group('page translation provider', () {
    testWidgets('loads cache on build and translate refreshes it',
        (tester) async {
      final repo = FakeTranslationRepo();
      final container = ProviderContainer(overrides: [
        translationRepositoryProvider.overrideWithValue(repo),
      ]);
      addTearDown(container.dispose);
      const key = (bookId: 1, page: 7);
      final node = container.read(pageTranslationProvider(key).notifier);
      final initial = await container.read(pageTranslationProvider(key).future);
      expect(initial.translation, isNull);

      await node.translate();
      final after = container.read(pageTranslationProvider(key)).valueOrNull!;
      expect(after.translation, isNotNull);
      expect(after.translation!.paragraphs.first.translated, '你好世界');
      expect(after.loading, isFalse);
      // Finishing must bump the render revision so the pane updates.
      expect(container.read(translationRevisionProvider), greaterThan(0));
    });
  });

  group('pane widget', () {
    testWidgets('shows the empty-service guide when unconfigured',
        (tester) async {
      final repo = FakeTranslationRepo()
        ..config = const TranslationConfig(
          provider: TranslationProviderKind.deepL,
          baseUrl: null,
          apiKey: null,
          model: null,
          sourceLang: 'auto',
          mode: TranslationMode.manual,
          backgroundBehavior: TranslationBackgroundBehavior.ask,
          autoOcr: true,
          concurrency: 2,
          cacheLimitMb: 2048,
        );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 400, child: TranslatedPane())),
        ),
      ));
      await tester.pump();
      // No book + no service -> the settings guide.
      expect(find.text('未配置翻译服务'), findsOneWidget);
    });

    testWidgets('renders the translated page beside the original (no overflow)',
        (tester) async {
      final repo = FakeTranslationRepo();
      tester.view.physicalSize = const Size(520, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          aiRepositoryProvider.overrideWithValue(FakeAiRepo()),
          translationRepositoryProvider.overrideWithValue(repo),
          defaultViewer(book: testBook(pageCount: 3), currentPage: 2),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedPane()),
        ),
      ));
      // runAsync so the page bitmap decodes.
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      // The page-level view shows the anchor and the rendered page image.
      expect(find.text('译文 p.2'), findsOneWidget);
      expect(find.byType(RawImage), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  });
}
