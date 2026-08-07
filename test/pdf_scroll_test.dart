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

/// Fake repository: renders a tiny 100x141 RGBA page without touching Rust.
class _FakeRepo extends ReaderRepository {
  @override
  Future<rust.PageRenderResult> renderPage(
    int bookId,
    int page,
    double zoom,
    double dpiScale,
  ) async {
    const w = 100, h = 141;
    return rust.PageRenderResult(
      width: w,
      height: h,
      rgba: Uint8List(w * h * 4),
      error: null,
    );
  }
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

Widget _app() => ProviderScope(
      overrides: [
        viewerProvider.overrideWith((ref) {
          final n = ViewerNotifier(ref);
          n.state = ViewerState(
            book: _book(),
            pageCount: 3,
            zoom: 1.2,
            loading: false,
          );
          return n;
        }),
        readerRepositoryProvider.overrideWithValue(_FakeRepo()),
      ],
      child: const MaterialApp(home: Scaffold(body: PdfPageScroll())),
    );

void main() {
  testWidgets('single mode renders pages without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_app());
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'single mode exception');
    });
  });

  testWidgets('double-scroll mode renders without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          viewerProvider.overrideWith((ref) {
            final n = ViewerNotifier(ref);
            n.state = ViewerState(
              book: _book(),
              pageCount: 4,
              zoom: 1.2,
              loading: false,
              mode: ViewMode.doubleScroll,
            );
            return n;
          }),
          readerRepositoryProvider.overrideWithValue(_FakeRepo()),
        ],
        child: const MaterialApp(home: Scaffold(body: PdfPageScroll())),
      ));
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'double-scroll mode exception');
    });
  });

  testWidgets('double-page mode renders without hang', (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          viewerProvider.overrideWith((ref) {
            final n = ViewerNotifier(ref);
            n.state = ViewerState(
              book: _book(),
              pageCount: 4,
              zoom: 1.2,
              loading: false,
              mode: ViewMode.doublePage,
            );
            return n;
          }),
          readerRepositoryProvider.overrideWithValue(_FakeRepo()),
        ],
        child: const MaterialApp(home: Scaffold(body: PdfPageScroll())),
      ));
      await tester.pump();
      await Future.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      expect(tester.takeException(), isNull,
          reason: 'double-page mode exception');
    });
  });
}
