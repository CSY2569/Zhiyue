import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart';
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_translation_repo.dart';
import 'helpers/widget_harness.dart';

void main() {
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

  group('对照 column widget', () {
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
          home: Scaffold(body: SizedBox(width: 400, child: TranslatedColumn())),
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
          home: const Scaffold(body: TranslatedColumn()),
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

    testWidgets('follows the original page when the reader turns pages',
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
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('译文 p.2'), findsOneWidget);

      // Turn to page 3 by advancing the viewer state (re-pumping a new
      // ProviderScope would NOT work: the scope's element is reused, so the
      // old container would survive).
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TranslatedColumn)),
        listen: false,
      );
      final notifier = container.read(viewerProvider.notifier);
      notifier.state = notifier.state.copyWith(currentPage: 3);
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('译文 p.3'), findsOneWidget);
      expect(find.text('译文 p.2'), findsNothing);
    });
  });
}
