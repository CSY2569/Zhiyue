import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/widgets/selection_layer.dart';
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart';
import 'package:rbwa/src/rust/models/annotation.dart'
    show NormRect, TextAnnotation, TextAnnotationKind;

import 'helpers/fake_translation_repo.dart';

/// Annotation list seeded for tests (no DB).
class _SeededAnnotations extends AnnotationNotifier {
  _SeededAnnotations(this.seed);

  final List<TextAnnotation> seed;

  @override
  Future<List<TextAnnotation>> build() async => seed;
}

void main() {
  /// Mounts the toolbar with a committed selection of [source].
  Widget harness(SelectionSource source) {
    final sel = Selection(
      page: 0,
      anchorIndex: 0,
      currentIndex: 3,
      text: '示例选中文本',
      lineRects: [
        NormRect(x: 0.1, y: 0.1, w: 0.5, h: 0.02),
      ],
      source: source,
    );
    return ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Stack(children: [
          const Scaffold(body: SizedBox.expand()),
          Builder(
            builder: (context) {
              // Commit the selection after the first frame (the toolbar
              // renders only committed selections).
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final container = ProviderScope.containerOf(context);
                container
                    .read(selectionProvider.notifier)
                    .commitSelection(sel, const Rect.fromLTWH(100, 100, 200, 16));
              });
              return const FloatingToolbar(bookId: 1, bookTitle: '测试书');
            },
          ),
        ]),
      ),
    );
  }

  testWidgets('原文选中：8 个按钮全在（AI + 复制 + 标注 + 笔记）', (tester) async {
    await tester.pumpWidget(harness(SelectionSource.original));
    await tester.pumpAndSettle();

    for (final label in ['翻译', '解释', '搜索', '复制', '高亮', '下划线', '删除线', '笔记']) {
      expect(find.text(label), findsOneWidget, reason: '$label 应显示');
    }
  });

  testWidgets('译文选中：与原文同样提供全部 8 个按钮', (tester) async {
    await tester.pumpWidget(harness(SelectionSource.translated));
    await tester.pumpAndSettle();

    // The full mark set works on the translated pane too (v9: marks are
    // stored with source='translated' and rendered on that pane only).
    for (final label in ['翻译', '解释', '搜索', '复制', '高亮', '下划线', '删除线', '笔记']) {
      expect(find.text(label), findsOneWidget, reason: '$label 应显示');
    }
  });

  /// The original page and the translated pane share page indices: a
  /// selection made on ONE pane must paint only there (regression: the
  /// original page used to light up when the user selected in the
  /// translation).
  group('选中预览只画在来源窗格', () {
    Selection sel(SelectionSource source) => Selection(
          page: 0,
          anchorIndex: 0,
          currentIndex: 2,
          text: '样例',
          lineRects: [NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.02)],
          source: source,
        );

    /// The preview painter received by the layer (null = nothing painted).
    Object? paintedSelection(WidgetTester tester) {
      final paints = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((w) => w.painter)
          .whereType<CustomPainter>()
          .toList();
      for (final p in paints) {
        // ignore: avoid_dynamic_calls
        final field = (p as dynamic).selection;
        if (field != null) return field;
      }
      return null;
    }

    Widget layer({required bool translated}) => ProviderScope(
          overrides: [
            translationRepositoryProvider.overrideWithValue(FakeTranslationRepo()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 400,
                  height: 560,
                  child: SelectionLayer(
                    bookId: 1,
                    page: 0,
                    annotations: const [],
                    translated: translated,
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets('译文选中不画在原文窗格', (tester) async {
      await tester.pumpWidget(layer(translated: false));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SelectionLayer)),
      );
      container.read(selectionProvider.notifier).commitSelection(
            sel(SelectionSource.translated),
            const Rect.fromLTWH(10, 10, 50, 10),
          );
      await tester.pumpAndSettle();
      expect(paintedSelection(tester), isNull, reason: '原文窗格不应画译文选中');
    });

    testWidgets('原文选中不画在译文窗格', (tester) async {
      await tester.pumpWidget(layer(translated: true));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SelectionLayer)),
      );
      container.read(selectionProvider.notifier).commitSelection(
            sel(SelectionSource.original),
            const Rect.fromLTWH(10, 10, 50, 10),
          );
      await tester.pumpAndSettle();
      expect(paintedSelection(tester), isNull, reason: '译文窗格不应画原文选中');
    });

    testWidgets('同来源选中照常画在对应窗格', (tester) async {
      await tester.pumpWidget(layer(translated: true));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SelectionLayer)),
      );
      final own = sel(SelectionSource.translated);
      container.read(selectionProvider.notifier).commitSelection(
            own,
            const Rect.fromLTWH(10, 10, 50, 10),
          );
      await tester.pumpAndSettle();
      expect(paintedSelection(tester), isNotNull, reason: '译文窗格应画译文选中');
    });
  });

  group('译文标注按窗格隔离', () {
    TextAnnotation ann(int id, int page, String source) => TextAnnotation(
          id: id,
          bookId: 1,
          page: page,
          kind: TextAnnotationKind.highlight,
          source: source,
          text: 't$id',
          content: null,
          rects: const [NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.02)],
          color: null,
          createdAt: '',
          updatedAt: '',
        );

    test('译文窗格只取 source=translated 的本页标注', () async {
      final seed = [
        ann(1, 2, 'original'),
        ann(2, 2, 'translated'),
        ann(3, 3, 'translated'),
      ];
      final container = ProviderContainer(overrides: [
        annotationProvider.overrideWith(() => _SeededAnnotations(seed)),
      ]);
      addTearDown(container.dispose);
      // Let the async notifier settle.
      await container.read(annotationProvider.future);

      final list = container.read(
        translatedPageAnnotationsProvider((bookId: 1, page: 2)),
      );
      expect(list.map((a) => a.id), [2], reason: '只应含本页的译文标注');
    });
  });
}
