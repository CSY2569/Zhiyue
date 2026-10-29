import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/library_filter_bar.dart';
import 'package:rbwa/features/reader/widgets/reader_toolbar.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/models/progress.dart' show ViewMode;

import 'helpers/fake_settings.dart';
import 'helpers/widget_harness.dart';

/// Regression coverage for the desktop-feedback round (floating toolbar row,
/// shelf filter axis + single selection indicator, rail dedup, inline
/// annotation tools, theme toggle).
void main() {
  group('浮动选择工具栏', () {
    testWidgets('desktop lays all eight actions out on one row', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: FloatingToolbar()),
        ),
      ));
      container.read(selectionProvider.notifier).commitSelection(
            Selection(
              page: 0,
              anchorIndex: 0,
              currentIndex: 2,
              text: 'hello world',
              lineRects: const [NormRect(x: 0.1, y: 0.1, w: 0.5, h: 0.03)],
            ),
            const Rect.fromLTWH(100, 100, 200, 20),
          );
      await tester.pump();

      final labels = ['翻译', '解释', '搜索', '复制', '高亮', '下划线', '删除线', '笔记'];
      final tops = {
        for (final label in labels)
          label: tester.getRect(find.text(label)).top.round(),
      };
      // A single row: every label shares the same vertical band.
      expect(tops.values.toSet(), hasLength(1),
          reason: 'one row expected, got $tops');
      expect(tester.takeException(), isNull);
    });

    for (final width in [360.0, 412.0, 600.0]) {
      testWidgets('touch layout at $width keeps one row of eight icons',
          (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: FloatingToolbar()),
          ),
        ));
        container.read(selectionProvider.notifier).commitSelection(
              Selection(
                page: 0,
                anchorIndex: 0,
                currentIndex: 2,
                text: 'hello world',
                lineRects: const [NormRect(x: 0.1, y: 0.1, w: 0.5, h: 0.03)],
              ),
              const Rect.fromLTWH(40, 200, 120, 18),
            );
        await tester.pump();

        final surface = find.byKey(const Key('selection-toolbar-surface'));
        final size = tester.getSize(surface);
        // One row: the bar is a thin strip, not the old 4×2 block (~124dp).
        expect(size.height, lessThan(70),
            reason: 'one-row toolbar expected, got $size');
        // All eight actions present, laid out side by side inside the bar.
        final icons = find.descendant(
          of: surface,
          matching: find.byType(Icon),
        );
        expect(icons.evaluate().length, 8);
        final tops = <int>{
          for (var i = 0; i < icons.evaluate().length; i++)
            tester.getCenter(icons.at(i)).dy.round(),
        };
        expect(tops, hasLength(1), reason: 'icons must share one row');
        // And the bar never exceeds the viewport it floats in.
        expect(size.width, lessThanOrEqualTo(width));
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('书架顶部筛选栏', () {
    testWidgets('only one entry is highlighted at a time', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: LibraryFilterBar(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // Tap PDF and inspect mid-animation: a single sliding indicator means
      // the number of opaque pill backgrounds never grows past one.
      await tester.tap(find.text('PDF'));
      await tester.pump(const Duration(milliseconds: 40));
      final tinted = tester
          .widgetList<AnimatedPositioned>(find.byType(AnimatedPositioned))
          .length;
      expect(tinted, 1, reason: 'exactly one selection indicator');
      await tester.pumpAndSettle();
      expect(container.read(libraryFilterProvider).type, LibraryType.pdf);
    });

    testWidgets('the type axis leaves the rail view untouched', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: LibraryFilterBar(),
            ),
          ),
        ),
      ));
      container.read(libraryFilterProvider.notifier).showFavorites();
      await tester.tap(find.text('图片'));
      await tester.pumpAndSettle();
      expect(container.read(libraryFilterProvider).view, LibraryView.favorite);
      expect(container.read(libraryFilterProvider).type, LibraryType.image);
    });
  });

  group('阅读顶栏批注工具', () {
    testWidgets('arming 批注 renders the tools inline, not as a second bar',
        (tester) async {
      tester.view.physicalSize = const Size(1400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final container = ProviderContainer(overrides: [
        seededViewer(ViewerState(
          book: testBook(pageCount: 30),
          pageCount: 30,
          currentPage: 5,
          zoom: 1.0,
          loading: false,
          mode: ViewMode.single,
        )),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: ReaderToolbar()),
        ),
      ));
      await tester.pump();

      // Before: normal reading controls are visible.
      expect(find.text('单页'), findsOneWidget);
      await tester.tap(find.byTooltip('批注'));
      await tester.pump();

      // After: the annotation tools replace the middle group in the SAME bar.
      expect(find.byTooltip('画笔'), findsOneWidget);
      expect(find.byTooltip('选择/移动'), findsOneWidget);
      expect(find.byTooltip('退出批注'), findsOneWidget);
      expect(find.text('单页'), findsNothing,
          reason: 'the mark tools take the middle section');
      // Everything still fits inside the toolbar row.
      final bar = tester.getRect(find.byType(ReaderToolbar));
      final exit = tester.getRect(find.byTooltip('退出批注'));
      expect(bar.contains(exit.center), isTrue);
      expect(tester.takeException(), isNull);

      // The 批注 toggle disarms and restores the reading controls.
      await tester.tap(find.byTooltip('批注'));
      await tester.pump();
      expect(find.text('单页'), findsOneWidget);
      expect(find.byTooltip('退出批注'), findsNothing);
    });
  });

  group('主题切换', () {
    test('toggle maps light -> night and night -> paper for every choice', () {
      expect(toggledReadingTheme(ReadingTheme.paper), ReadingTheme.night);
      expect(toggledReadingTheme(ReadingTheme.parchment), ReadingTheme.night);
      expect(toggledReadingTheme(ReadingTheme.night), ReadingTheme.paper);
      // Auto resolves to a concrete theme first, so it toggles too.
      expect(
        toggledReadingTheme(
          resolveReadingTheme(
              ReadingTheme.auto, ThemeMode.light, Brightness.light),
        ),
        ReadingTheme.night,
      );
    });

    testWidgets('reading theme choice drives the app-wide theme',
        (tester) async {
      final fake = FakeSettings();
      final container = ProviderContainer(overrides: [
        settingsRepositoryProvider.overrideWithValue(fake),
      ]);
      addTearDown(container.dispose);
      await container
          .read(readingThemeControllerProvider.notifier)
          .set(toggledReadingTheme(ReadingTheme.parchment));
      expect(container.read(readingThemeControllerProvider), ReadingTheme.night);
      expect(fake.writes['reading_theme'], 'night');
    });
  });
}
