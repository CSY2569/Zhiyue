import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/book_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/features/annotation/widgets/selection_layer.dart';
import 'package:rbwa/src/rust/models/annotation.dart'
    show NormRect, TextAnnotation, TextAnnotationKind;
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart';
import 'package:rbwa/src/rust/models/progress.dart' show ViewMode;

import 'helpers/fake_translation_repo.dart';
import 'helpers/widget_harness.dart';

void main() {
  group('对照 pane state', () {
    test('toggle forces single-page and close restores the mode', () {
      final container = ProviderContainer(overrides: [
        translationRepositoryProvider.overrideWithValue(FakeTranslationRepo()),
        defaultViewer(book: testBook(pageCount: 3)),
      ]);
      addTearDown(container.dispose);

      // Start in double-page mode.
      container.read(viewerProvider.notifier).setMode(ViewMode.doublePage);
      expect(container.read(translationPaneProvider).open, isFalse);

      // Opening 对照 remembers the mode and switches to single.
      container.read(translationPaneProvider.notifier).toggle();
      expect(container.read(translationPaneProvider).open, isTrue);
      expect(container.read(translationPaneProvider).modeBefore,
          ViewMode.doublePage);
      expect(container.read(viewerProvider).mode, ViewMode.single);

      // Closing restores it.
      container.read(translationPaneProvider.notifier).close();
      expect(container.read(translationPaneProvider).open, isFalse);
      expect(container.read(viewerProvider).mode, ViewMode.doublePage);
    });
  });

  group('对照 column widget', () {
    testWidgets('prompts for a book when none is open', (tester) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(FakeTranslationRepo()),
          // defaultViewer() always seeds a book; build an empty viewer state.
          seededViewer(const ViewerState(loading: false)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      await tester.pump();
      expect(find.text('打开一本书后即可对照阅读'), findsOneWidget);
    });

    testWidgets('shows the missing-engine guide with a book open',
        (tester) async {
      tester.view.physicalSize = const Size(520, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(FakeTranslationRepo()),
          defaultViewer(book: testBook(pageCount: 3), currentPage: 2),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      await tester.pumpAndSettle();

      // A build without an assembled engine shows the build-time guide and
      // renders without overflow.
      expect(find.text('未找到翻译引擎'), findsOneWidget);
      expect(find.text('前往设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('engine installed without artifact offers the translate action',
        (tester) async {
      final repo = FakeTranslationRepo()
        ..engineStatus = const EngineStatus(
          kind: EngineStatusKind.installed,
          phase: '',
          progress: 1,
          version: '2.9.0',
          sizeBytes: 1024,
          error: null,
          bundled: true,
        );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(repo),
          defaultViewer(book: testBook(pageCount: 3), currentPage: 2),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      // Spinners animate forever: bounded pumps, not pumpAndSettle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('翻译本书'), findsOneWidget);
      expect(find.text('开始翻译'), findsOneWidget);

      // Start the run (fake streams two events, then refresh reads the
      // artifact the test pre-seeds).
      final started = DateTime.now();
      repo.bookTranslation = BookTranslation(
        bookId: 1,
        title: '测试书',
        targetLang: '中文',
        langOut: 'zh',
        monoPath: '/x.mono.pdf',
        dualPath: '/x.dual.pdf',
        pages: 3,
        finishedAt: started.millisecondsSinceEpoch.toString(),
      );
      await tester.tap(find.text('开始翻译'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(repo.translateCalls, 1);
      // The artifact is present now: the synced page list renders p.N chips.
      expect(find.text('p.2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('译文选中层与图像显示矩形完全重合（几何回归）', (tester) async {
      tester.view.physicalSize = const Size(520, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = FakeTranslationRepo()
        ..engineStatus = const EngineStatus(
          kind: EngineStatusKind.installed,
          phase: '',
          progress: 1,
          version: 'retainpdf-pipeline 4.2.6',
          sizeBytes: 1024,
          error: null,
          bundled: true,
        )
        ..bookTranslation = BookTranslation(
          bookId: 1,
          title: '测试书',
          targetLang: '中文',
          langOut: 'zh',
          monoPath: '/x.mono.pdf',
          dualPath: '',
          pages: 3,
          finishedAt: '0',
        );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(repo),
          annotationProvider.overrideWith(() => _SeededAnnotations([
                TextAnnotation(
                  id: 1,
                  bookId: 1,
                  page: 0,
                  kind: TextAnnotationKind.highlight,
                  source: 'translated',
                  text: '译文句子',
                  content: null,
                  rects: const [NormRect(x: 0.1, y: 0.1, w: 0.4, h: 0.02)],
                  color: '#ffff00',
                  createdAt: '',
                  updatedAt: '',
                ),
              ])),
          defaultViewer(book: testBook(pageCount: 3), currentPage: 1),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The page bitmap decodes on the engine (ui.decodeImageFromPixels):
      // give the real event loop a slice, then pump the result in.
      await tester.runAsync(() => Future<void>.delayed(
            const Duration(milliseconds: 100),
          ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final images = find.byType(RawImage);
      expect(images, findsWidgets, reason: '译文页应已渲染图像');
      final layer = find.byType(SelectionLayer);
      expect(layer, findsWidgets, reason: '译文页应带选中层');

      // The image is letterboxed (2:3 inside a wider card): the layer must
      // cover the IMAGE rect, not the whole card.
      final imageRect = tester.getRect(images.first);
      final layerRect = tester.getRect(layer.first);
      expect(layerRect.left, closeTo(imageRect.left, 0.5), reason: '左边对齐');
      expect(layerRect.top, closeTo(imageRect.top, 0.5), reason: '顶边对齐');
      expect(layerRect.width, closeTo(imageRect.width, 0.5), reason: '宽度一致');
      expect(layerRect.height, closeTo(imageRect.height, 0.5), reason: '高度一致');
      expect(tester.takeException(), isNull);

      // Marks made on the translated pane are painted there (v9 pane tag).
      final painted = tester
          .widget<HighlightLayer>(find.byType(HighlightLayer).first)
          .annotations;
      expect(painted, isNotEmpty, reason: '译文标注应在译文页渲染');
      expect(
        painted.every((a) => a.source == 'translated'),
        isTrue,
        reason: '译文页只画译文标注',
      );
    });

    testWidgets('running translation shows phase + cancel', (tester) async {
      final repo = FakeTranslationRepo()
        ..engineStatus = const EngineStatus(
          kind: EngineStatusKind.installed,
          phase: '',
          progress: 1,
          version: '2.9.0',
          sizeBytes: 0,
          error: null,
          bundled: true,
        )
        ..bookTranslateRunning = true;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          translationRepositoryProvider.overrideWithValue(repo),
          defaultViewer(book: testBook(pageCount: 3)),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: TranslatedColumn()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // No artifact yet -> ready state; drive the controller into running.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TranslatedColumn)),
        listen: false,
      );
      container.read(bookTranslationProvider(1).notifier).state =
          const AsyncData(BookTranslationState(
        running: true,
        phase: '翻译中',
        detail: 'start to translate',
        loaded: true,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('翻译中'), findsOneWidget);
      expect(find.text('取消翻译'), findsOneWidget);
      expect(find.textContaining('start to translate'), findsOneWidget);
    });
  });
}

/// Annotation list seeded for tests (no DB).
class _SeededAnnotations extends AnnotationNotifier {
  _SeededAnnotations(this.seed);

  final List<TextAnnotation> seed;

  @override
  Future<List<TextAnnotation>> build() async => seed;
}
