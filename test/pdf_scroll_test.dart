import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Fake repository: renders a real-proportioned A4 RGBA page (400x565)
/// without touching Rust.
class _FakeRepo extends ReaderRepository {
  @override
  Future<rust.PageRenderResult> renderPage(
    int bookId,
    int page,
    double zoom,
    double dpiScale,
  ) async {
    const w = 400, h = 565;
    return rust.PageRenderResult(
      width: w,
      height: h,
      rgba: Uint8List(w * h * 4),
      error: null,
    );
  }

  @override
  Future<rust.CharBoxResult> extractText(int bookId, int page) async =>
      rust.CharBoxResult(boxes: const [], error: null);

  @override
  Future<bool> pageHasText(int bookId, int page) async => false;
}

Book _book() => Book(
      id: 1,
      title: 'test',
      originalPath: '/x.pdf',
      storedPath: '/x.pdf',
      fileType: BookType.pdf,
      pageCount: 3,
      coverPath: null,
      favorite: false,
      categoryId: null,
      lastOpenedAt: null,
      importedAt: 'now',
    );

/// PdfPageScroll in a [width]x600 box. A narrow width + high zoom makes the
/// page wider than the viewport (regression: overflow / zebra stripes).
Widget _app(ViewMode mode, {double zoom = 1.2, double width = 800}) =>
    ProviderScope(
      overrides: [
        viewerProvider.overrideWith((ref) {
          final n = ViewerNotifier(ref);
          n.state = ViewerState(
            book: _book(),
            pageCount: 4,
            zoom: zoom,
            loading: false,
            mode: mode,
          );
          return n;
        }),
        readerRepositoryProvider.overrideWithValue(_FakeRepo()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 600,
              child: PdfPageScroll(),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('single mode renders pages without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(ViewMode.single));
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'single mode exception');
    });
  });

  testWidgets('double-scroll mode renders without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(ViewMode.doubleScroll));
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'double-scroll mode exception');
    });
  });

  testWidgets('double-page mode renders without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(ViewMode.doublePage));
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'double-page mode exception');
    });
  });

  // Regression (originally overflow_repro_test): a 200px viewport with
  // zoom 4.0 makes the page wider than the viewport (100 -> 400px), like
  // zooming a doc against the sidebar.
  for (final mode in ViewMode.values) {
    testWidgets('$mode: page wider than viewport does not overflow',
        (tester) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(_app(mode, zoom: 4.0, width: 200));
        await tester.pump();
        await Future.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        final e = tester.takeException();
        expect(e, isNull, reason: '$mode overflow: $e');
        if (mode == ViewMode.single) {
          // Single mode uses UnconstrainedBox; Clip.hardEdge must be set so
          // zooming past the viewport clips the page instead of painting the
          // debug zebra-stripe overflow indicator.
          final boxes = tester
              .widgetList<UnconstrainedBox>(find.byType(UnconstrainedBox));
          expect(boxes, isNotEmpty);
          for (final ub in boxes) {
            expect(ub.clipBehavior, Clip.hardEdge);
          }
        }
      });
    });
  }

  testWidgets('scan prompt anchors to the page top-left (not the viewport)',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_app(ViewMode.single));
      await tester.pump();
      // The fake repo reports no text layer: the page's own prompt bar shows.
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('扫描识别'), findsOneWidget);

      // Structural: the bar is a descendant of the page's Stack (the one
      // hosting the page bitmap), so it scrolls with the page instead of
      // floating over the viewport.
      final pageStack = find
          .ancestor(
              of: find.byType(RawImage).first, matching: find.byType(Stack))
          .first;
      expect(
        find.descendant(of: pageStack, matching: find.text('扫描识别')),
        findsOneWidget,
      );

      // Anchored: the bar's left edge sits at the page origin + (8, 8)
      // (the bar's Row sits 12/4 inside its padding).
      final barLeft = tester.getTopLeft(find
              .ancestor(
                  of: find.text('扫描识别'), matching: find.byType(Row))
              .first) -
          const Offset(12, 4);
      final page = tester.getTopLeft(find.byType(RawImage).first);
      expect(barLeft.dx - page.dx, closeTo(8, 1));
      expect(barLeft.dy - page.dy, closeTo(8, 1));
      expect(tester.takeException(), isNull);
    });
  });
}
