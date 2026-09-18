import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
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

    testWidgets('shows the engine-download guide with a book open',
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

      // The built-in pipeline is retired: the column guides the user to the
      // engine download in settings, and renders without overflow.
      expect(find.text('尚未安装翻译引擎'), findsOneWidget);
      expect(find.text('前往设置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}