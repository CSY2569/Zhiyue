import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart';
import 'package:rbwa/features/reader/widgets/scan_overlay.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart' show Book;
import 'package:rbwa/src/rust/models/progress.dart' show ReadingProgress, ViewMode;
import 'helpers/widget_harness.dart';

/// The book row served by getBook (a 10-page PDF).
Book _book() => testBook(pageCount: 10);

class _FakeLibraryRepo extends LibraryRepository {
  @override
  Future<Book?> getBook(int id) async => _book();
}

/// Fake repository: the full openBook flow (open + progress restore + text
/// checks) without touching Rust.
class _FakeOpenRepo extends ReaderRepository {
  int restoredPage = 5; // saved reading position (1-indexed)
  ViewMode restoredMode = ViewMode.single;
  bool hasText = false;

  @override
  Future<rust.OpenBookResult> openBook(String storedPath) async =>
      const rust.OpenBookResult(pageCount: 10, hasOutline: false, error: null);

  @override
  Future<ReadingProgress?> getProgress(int bookId) async => ReadingProgress(
        bookId: bookId,
        page: restoredPage,
        zoom: 1.2,
        viewMode: restoredMode,
        updatedAt: 'now',
      );

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
  Future<bool> pageHasText(int bookId, int page) async => hasText;
}

void main() {
  testWidgets(
      'book restored to a middle page still shows the scan prompt there',
      (tester) async {
    final repo = _FakeOpenRepo()..restoredPage = 5;
    // Real async (ui.decodeImageFromPixels) never completes in the fake
    // async zone, so the render flow must run inside runAsync.
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          readerRepositoryProvider.overrideWithValue(repo),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepo()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 600,
                child: PdfPageScroll(),
              ),
            ),
          ),
        ),
      ));

      // Drive the real openBook flow: open the book, which restores page 5.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PdfPageScroll)),
      );
      await container.read(viewerProvider.notifier).openBook(1);
      // Let the render + scroll jump + text-layer checks land (decode is
      // real async; ScanOverlay renders only after the page bitmap lands).
      for (var i = 0; i < 10 && find.byType(ScanOverlay).evaluate().isEmpty; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // The viewer must land on the restored page.
      expect(container.read(viewerProvider).currentPage, 5);

      // Both halves of the restored spread get their scan prompt (pages 4/5,
      // 0-indexed) -- regression: opening in the middle dropped the checks.
      expect(find.byType(ScanOverlay), findsWidgets);
      expect(find.textContaining('整页扫描识别'), findsWidgets);
      for (final page0 in [4, 5]) {
        final phase = container.read(scanStateProvider).of(page0)?.phase;
        expect(phase, ScanPhase.prompt,
            reason: 'page $page0 must offer 扫描识别');
      }
    });
  });

  testWidgets(
      'double-page mode opened on an even (right-half) page checks the '
      'visible spread (not the next page)', (tester) async {
    final repo = _FakeOpenRepo()
      ..restoredPage = 6 // 1-indexed even page = right half of pair (5, 6)
      ..restoredMode = ViewMode.doublePage;
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          readerRepositoryProvider.overrideWithValue(repo),
          libraryRepositoryProvider.overrideWithValue(_FakeLibraryRepo()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 800,
                height: 600,
                child: PdfPageScroll(),
              ),
            ),
          ),
        ),
      ));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PdfPageScroll)),
      );
      await container.read(viewerProvider.notifier).openBook(1);
      for (var i = 0; i < 10; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }

      // The restored page (right half of the pair) must survive the
      // PageView's first-layout report -- snapping it to the left page
      // re-checks the wrong spread and the prompt never lands here.
      expect(container.read(viewerProvider).currentPage, 6,
          reason: 'opening on an even page must not snap to the left page');
      // Visible spread is the pair (5, 6) 1-indexed = (4, 5) 0-indexed. The
      // old code checked {5, 6} 0-indexed (pages 6, 7) -- the right half
      // plus the OFF-SCREEN next page -- and missed the left half. Both
      // halves of the visible pair must carry a prompt; the off-screen page
      // (0-indexed 6) must NOT have been checked.
      for (final page0 in [4, 5]) {
        final phase = container.read(scanStateProvider).of(page0)?.phase;
        expect(phase, ScanPhase.prompt,
            reason: 'visible page $page0 (0-indexed) must offer 扫描识别');
      }
      expect(container.read(scanStateProvider).of(6), isNull,
          reason: 'off-screen page 6 (0-indexed) must not be checked');
    });
  });
}
