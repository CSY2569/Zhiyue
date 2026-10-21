import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/data/repositories/text_translation_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/library/library_page.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/features/library/widgets/library_filter_bar.dart';
import 'package:rbwa/features/library/widgets/category_rail.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';

import 'package:rbwa/features/settings/widgets/settings_widgets.dart';
import 'package:rbwa/src/rust/models/ai.dart';
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/ai_config_fixture.dart';
import 'helpers/widget_harness.dart';

/// 360 × 780 dp -- the small-phone layout the plan targets. Any RenderFlex
/// overflow surfaces as an exception, so these tests catch the desktop-sized
/// layouts that used to be reachable only on a phone.
void _usePhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);
}

Selection _selection() => const Selection(
      page: 0,
      anchorIndex: 0,
      currentIndex: 5,
      text: 'Hello world',
      lineRects: [NormRect(x: 0.1, y: 0.2, w: 0.5, h: 0.04)],
    );

void main() {
  group('phone layout (360dp)', () {
    testWidgets('filter bar fits without overflow', (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(12),
              child: LibraryFilterBar(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('book tile keeps a 48dp favorite target', (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                // The cell must follow the same formula the grid uses, or the
                // card's aspect-ratio cover + text block overflows.
                height: Golden.cellHeightFor(160),
                child: BookTile(
                  book: testBook(),
                  enableDrag: false,
                  onTap: () {},
                  onToggleFavorite: () {},
                  onAssignCategory: () {},
                  onDelete: () {},
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The favourite toggle is a gesture area on the cover corner (the
      // visual star is 16dp); its hit target must still be >= 48dp.
      final button = tester.getSize(
        find
            .descendant(
              of: find.byType(BookTile),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is GestureDetector &&
                    w.onTap != null &&
                    w.behavior == HitTestBehavior.opaque,
              ),
            )
            .last,
      );
      expect(button.width, greaterThanOrEqualTo(48));
      expect(button.height, greaterThanOrEqualTo(48));
    });

    testWidgets('selection toolbar docks at the bottom and does not throw',
        (tester) async {
      _usePhoneSurface(tester);
      late ProviderContainer container;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          aiConfigProvider.overrideWith(() => _FixedAiConfig(testAiConfig())),
          textTranslationRepositoryProvider
              .overrideWithValue(_NoopTextRepo()),
        ],
        child: Builder(
          builder: (context) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: AppTheme.light(),
              home: const Scaffold(
                body: Stack(
                  children: [FloatingToolbar()],
                ),
              ),
            );
          },
        ),
      ));

      // Anchor the toolbar the way SelectionLayer does on a real selection.
      container.read(selectionProvider.notifier).commitSelection(
            _selection(),
            const Rect.fromLTWH(120, 500, 80, 20),
          );
      await tester.pumpAndSettle();

      if (tester.takeException() case final e?) {
        fail('selection toolbar threw on a phone: $e');
      }
      // All eight actions are present in the docked 4×2 grid.
      for (final label in ['翻译', '解释', '搜索', '复制', '高亮', '下划线', '删除线', '笔记']) {
        expect(find.text(label), findsOneWidget);
      }
      // Docked at the bottom: the bar's top edge sits in the lower half.
      final bar = tester.getRect(find.text('翻译'));
      expect(bar.center.dy, greaterThan(390));
    });

    testWidgets('tablet-sized library grid lays out without overflow',
        (tester) async {
      // 11" tablet: 1600x2560 @ 2.0 => 800x1280 dp.
      tester.view.physicalSize = const Size(1600, 2560);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(ProviderScope(
        overrides: [
          libraryBooksProvider.overrideWith(() => _ManyBooksNotifier()),
          // The full page triggers a background index probe, which needs the
          // Rust core; stub it out for this layout-only test.
          searchIndexStatusProvider
              .overrideWith(_NoIndexProbe.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const LibraryPage(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The permanent rail and the page header are both present.
      expect(find.byType(CategoryRail), findsOneWidget);
      expect(find.text('我的书库'), findsOneWidget);
      expect(find.byType(BookTile), findsWidgets);
    });

    testWidgets('settings control rows stay full width', (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SettingsControlRow(
              title: 'OpenAI 兼容服务',
              description: '填写地址、Key 与模型名。',
              child: TextField(
                decoration: const InputDecoration(hintText: 'https://…'),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

/// No-op index status: `refresh()` never touches the FFI in layout tests.
class _NoIndexProbe extends SearchIndexStatusNotifier {
  @override
  Future<void> refresh() async {}
}

/// Six books so the grid has multiple rows at tablet width.
class _ManyBooksNotifier extends LibraryBooksNotifier {
  @override
  Future<List<Book>> build() async => [
        for (var i = 1; i <= 6; i++) testBook(id: i, title: '书 $i'),
      ];

  @override
  Future<void> refresh() async {
    state = AsyncData([
      for (var i = 1; i <= 6; i++) testBook(id: i, title: '书 $i'),
    ]);
  }
}

/// Minimal AI config (no repository reads).
class _FixedAiConfig extends AiConfigNotifier {
  _FixedAiConfig(this.config);

  final AiConfig config;

  @override
  Future<AiConfig> build() async => config;
}

/// The toolbar's AI actions need the repository for translation lookups; the
/// tests never trigger them, so a no-op implementation is enough.
class _NoopTextRepo implements TextTranslationRepository {
  @override
  Future<int> cancel() async => 1;

  @override
  Future<int> clearBook(int bookId) async => 0;

  @override
  Future<PageTextTranslation?> getCached(
    int bookId,
    int page,
    String targetLang,
  ) async =>
      null;

  @override
  Future<PageTextBlocks> getPageBlocks(int bookId, int page) async =>
      PageTextBlocks(
        page: page,
        width: 600,
        height: 800,
        blocks: const [],
        error: null,
      );

  @override
  Future<PageTextTranslation> translatePage({
    required int bookId,
    required int page,
    required String targetLang,
    bool force = false,
  }) async =>
      PageTextTranslation(
        page: page,
        width: 0,
        height: 0,
        targetLang: targetLang,
        model: '',
        blocks: const [],
        cached: false,
        error: null,
      );

  @override
  Future<int> translatedPageCount(int bookId, String targetLang) async => 0;
}
