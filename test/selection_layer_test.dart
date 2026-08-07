import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/selection_layer.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Pre-seeded char-box cache so the layer hit-tests without Rust.
/// `getOrFetch` is overridden so the layer's preload never touches the real
/// FRB bindings in tests.
class _FakeCharBoxCache extends CharBoxCache {
  _FakeCharBoxCache(this.boxes);

  final List<CharBox> boxes;

  @override
  Map<int, List<CharBox>> build() => {0: boxes};

  @override
  Future<List<CharBox>> getOrFetch(int bookId, int page) async => boxes;
}

/// Cache that starts empty and fills itself only when the layer's preload
/// calls `getOrFetch` -- simulates the real load path (FEATURES 4.1.2).
class _LazyCharBoxCache extends CharBoxCache {
  static final _boxes = oneLine();

  @override
  Map<int, List<CharBox>> build() => {};

  @override
  Future<List<CharBox>> getOrFetch(int bookId, int page) async {
    state = {page: _boxes};
    return _boxes;
  }
}

CharBox box(String ch, double x, double y,
        {double w = 0.01, double h = 0.02}) =>
    CharBox(char: ch, x: x, y: y, w: w, h: h);

/// One line of four chars at normalized y 0.10 (screen y 10..12 of a 100x100
/// layer).
List<CharBox> oneLine() => [
      box('a', 0.10, 0.10),
      box('b', 0.20, 0.10),
      box('c', 0.30, 0.10),
      box('d', 0.40, 0.10),
    ];

Widget harness(List<CharBox> boxes) => ProviderScope(
      overrides: [
        charBoxCacheProvider.overrideWith(() => _FakeCharBoxCache(boxes)),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: SelectionLayer(bookId: 0, page: 0, annotations: []),
            ),
          ),
        ),
      ),
    );

SelectionUiState stateOf(WidgetTester tester) => ProviderScope.containerOf(
      tester.element(find.byType(SelectionLayer)),
    ).read(selectionProvider);

void main() {
  testWidgets('drag selects characters and anchors the toolbar above',
      (tester) async {
    await tester.pumpWidget(harness(oneLine()));
    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));

    // Drag across b..d (20..60 px on the line at y=11). The first move only
    // passes the touch slop (accepting the pan); the second extends it.
    final g = await tester.startGesture(topLeft + const Offset(20, 11));
    await g.moveTo(topLeft + const Offset(40, 11));
    await g.moveTo(topLeft + const Offset(60, 11));
    await g.up();
    await tester.pump();

    final sel = stateOf(tester).selection;
    expect(sel, isNotNull);
    expect(sel!.page, 0);
    expect(sel.text, 'bcd');
    // One tight line rect covering b..d (x 0.20..0.41).
    expect(sel.lineRects, hasLength(1));
    expect(sel.lineRects[0].x, closeTo(0.20, 1e-9));
    expect(sel.lineRects[0].w, closeTo(0.21, 1e-9));

    // Drag end committed the toolbar anchor above the first line.
    final anchor = stateOf(tester).toolbarAnchor;
    expect(anchor, isNotNull);
    // Anchor sits at the selection's first line (layer top + 10px line top).
    expect(anchor!.top, lessThanOrEqualTo(topLeft.dy + 10));
    expect(anchor.left, greaterThanOrEqualTo(topLeft.dx));
    expect(tester.takeException(), isNull);
  });

  testWidgets('backward drag selects the same range (reverse direction)',
      (tester) async {
    await tester.pumpWidget(harness(oneLine()));
    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));

    final g = await tester.startGesture(topLeft + const Offset(60, 11));
    await g.moveTo(topLeft + const Offset(40, 11));
    await g.moveTo(topLeft + const Offset(20, 11));
    await g.up();
    await tester.pump();

    final sel = stateOf(tester).selection;
    expect(sel, isNotNull);
    expect(sel!.text, 'bcd');
    expect(sel.lineRects, hasLength(1));
  });

  testWidgets('drag starting in whitespace selects nothing', (tester) async {
    await tester.pumpWidget(harness(oneLine()));
    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));

    // y=80 px is far below the text line (y 10..12).
    final g = await tester.startGesture(topLeft + const Offset(50, 80));
    await g.moveTo(topLeft + const Offset(70, 80));
    await g.up();
    await tester.pump();

    expect(stateOf(tester).selection, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap on whitespace clears an existing selection',
      (tester) async {
    await tester.pumpWidget(harness(oneLine()));
    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));

    // Select first, then tap whitespace (FEATURES 4.1.3).
    final g = await tester.startGesture(topLeft + const Offset(20, 11));
    await g.moveTo(topLeft + const Offset(60, 11));
    await g.up();
    await tester.pump();
    expect(stateOf(tester).selection, isNotNull);

    await tester.tapAt(topLeft + const Offset(50, 80));
    await tester.pump();
    expect(stateOf(tester).selection, isNull);
    expect(stateOf(tester).toolbarAnchor, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no text layer: drag is a no-op', (tester) async {
    await tester.pumpWidget(harness(const []));
    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));

    final g = await tester.startGesture(topLeft + const Offset(20, 11));
    await g.moveTo(topLeft + const Offset(40, 11));
    await g.moveTo(topLeft + const Offset(60, 11));
    await g.up();
    await tester.pump();

    expect(stateOf(tester).selection, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('preloads char boxes so the first drag selects (FEATURES 4.1.2)',
      (tester) async {
    // Cache starts empty; the layer must fetch it on init.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        charBoxCacheProvider.overrideWith(_LazyCharBoxCache.new),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 100,
              height: 100,
              child: SelectionLayer(bookId: 0, page: 0, annotations: []),
            ),
          ),
        ),
      ),
    ));
    // Let the post-frame preload run and the provider rebuild settle.
    await tester.pumpAndSettle();

    final topLeft = tester.getTopLeft(find.byType(SelectionLayer));
    final g = await tester.startGesture(topLeft + const Offset(20, 11));
    await g.moveTo(topLeft + const Offset(40, 11));
    await g.moveTo(topLeft + const Offset(60, 11));
    await g.up();
    await tester.pump();

    final sel = stateOf(tester).selection;
    expect(sel, isNotNull);
    expect(sel!.text, 'bcd');
    expect(tester.takeException(), isNull);
  });
}
