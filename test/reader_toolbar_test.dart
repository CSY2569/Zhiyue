import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/widget_harness.dart';
import 'package:rbwa/features/reader/widgets/reader_toolbar.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Fake viewer state so the toolbar renders without Rust.
Widget _app({ViewMode mode = ViewMode.single}) => ProviderScope(
      overrides: [
        seededViewer(ViewerState(
          pageCount: 10,
          currentPage: 1,
          zoom: 1.2,
          loading: false,
          mode: mode,
        )),
      ],
      child: const MaterialApp(
        home: Scaffold(body: ReaderToolbar()),
      ),
    );

void main() {
  testWidgets('toolbar shows sidebar toggles, mode selector, and AI controls',
      (tester) async {
    await tester.pumpWidget(_app());

    // Sidebar toggles on the left.
    expect(find.byTooltip('缩略图'), findsOneWidget);
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('标注'), findsOneWidget);

    // Mode selector shows the current mode (single).
    expect(find.text('单页'), findsOneWidget);

    // AI controls on the right: the AI toggle.
    expect(find.byTooltip('AI'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode selector popup switches view modes', (tester) async {
    await tester.pumpWidget(_app());

    await tester.tap(find.byType(PopupMenuButton<ViewMode>));
    await tester.pumpAndSettle();

    // All three modes offered.
    expect(find.text('单页'), findsWidgets); // button + menu item
    expect(find.text('双滚'), findsOneWidget);
    expect(find.text('双翻'), findsOneWidget);

    await tester.tap(find.text('双翻'));
    await tester.pumpAndSettle();

    final state = ProviderScope.containerOf(
      tester.element(find.byType(ReaderToolbar)),
    ).read(viewerProvider);
    expect(state.mode, ViewMode.doublePage);
    // The button now shows the new mode.
    expect(find.text('双翻'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
