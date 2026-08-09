import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/main.dart' as app;
import 'package:rbwa/src/rust/api.dart' as rust;

/// Real-app reproduction of "整页 OCR 不加载 when a scanned book opens on a
/// middle page": open 《鸟哥的Linux私房菜》 (book 8, progress at page 353) and
/// jump there via full-text search; in both cases the restored/jumped page
/// must carry a scan state (prompt or success) -- never be left blank.
/// Requires the user's real database + the Rust core; run with:
///   flutter test -d linux integration_test/scan_middle_page_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('scanned book opened or jumped to a middle page gets scan state',
      (tester) async {
    app.main();
    // Startup: window + FRB + core init. The library grid loads async from
    // SQLite; its thumbnails render async too, so poll instead of settling.
    var found = false;
    for (var i = 0; i < 200 && !found; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      found = find.textContaining('鸟哥').evaluate().isNotEmpty;
    }
    expect(found, isTrue, reason: 'library grid must show the scanned book');
    // Pin the restored position so the test is idempotent (the search-jump
    // scenario below persists progress, which would otherwise shift the
    // restore target on the next run). RustLib is initialized by now.
    await rust.saveProgress(
        bookId: 8, page: 353, zoom: 1.9, viewMode: 'single');

    ProviderContainer container() => ProviderScope.containerOf(
          tester.element(find.byType(Scaffold).last),
        );

    // --- Scenario 1: open the book from the library; progress restores to
    // page 353 (a scanned middle page). ---
    await tester.tap(find.textContaining('鸟哥'));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final viewer = container().read(viewerProvider);
      if (!viewer.loading && viewer.book?.id == 8) break;
    }
    final viewer1 = container().read(viewerProvider);
    debugPrint('open: book=${viewer1.book?.id} page=${viewer1.currentPage} '
        'pages=${viewer1.pageCount}');
    expect(viewer1.currentPage, 353,
        reason: 'progress restore must land on page 353');

    // Wait for the text-layer checks to land (real async FRB calls).
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final scan = container().read(scanStateProvider);
      if ((scan.of(352)?.phase == ScanPhase.prompt ||
              scan.of(352)?.phase == ScanPhase.success) &&
          (scan.of(353)?.phase == ScanPhase.prompt ||
              scan.of(353)?.phase == ScanPhase.success)) {
        break;
      }
    }
    var scan = container().read(scanStateProvider);
    debugPrint('scan after open: '
        '${scan.pages.entries.map((e) => '${e.key}:${e.value.phase.name}').join(', ')}');
    for (final page0 in [352, 353]) {
      final phase = scan.of(page0)?.phase;
      expect(phase == ScanPhase.prompt || phase == ScanPhase.success, isTrue,
          reason: 'restored spread page $page0 must carry a scan state');
    }

    // --- Scenario 1b: if the restored page is unscanned, run the real
    // full-page scan (renders at original resolution + OCR engine; models
    // are installed) and require it to reach a terminal state. ---
    final needed = container().read(scanStateProvider).of(352)?.phase ==
        ScanPhase.prompt;
    if (needed) {
      // The prompt renders only after the page bitmap lands; wait for it.
      for (var i = 0; i < 150; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        if (find.text('扫描识别').evaluate().isNotEmpty) break;
      }
      final scanButtons = find.text('扫描识别');
      expect(scanButtons, findsWidgets,
          reason: 'scan prompt must be clickable on the restored page');
      await tester.tap(scanButtons.first);
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        final phase = container().read(scanStateProvider).of(352)?.phase;
        if (phase == ScanPhase.success ||
            phase == ScanPhase.empty ||
            phase == ScanPhase.error) {
          break;
        }
      }
      final scanned = container().read(scanStateProvider).of(352);
      debugPrint('scan result on page 352: ${scanned?.phase.name} '
          'error=${scanned?.error} lowConf=${scanned?.lowConfidence}');
      expect(scanned?.phase, ScanPhase.success,
          reason: 'real scan must succeed on page 352, '
              'got ${scanned?.phase.name}');
    } else {
      debugPrint('page 352 already scanned in a previous run; skipping scan');
    }

    // --- Back to the library. ---
    await tester.tap(find.byIcon(Icons.arrow_back).first);
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byIcon(Icons.manage_search).evaluate().isNotEmpty) break;
    }

    // --- Scenario 2: jump via full-text search. "相对路径" is indexed from
    // book 8's OCR page 8 (0-indexed 7). ---
    await tester.tap(find.byIcon(Icons.manage_search));
    // Wait for the *full-text* search field (the library toolbar also has a
    // title-search field, so match the hint).
    final fullTextField = find.byWidgetPredicate(
      (w) => w is TextField &&
          (w.decoration?.hintText?.contains('全文') ?? false),
    );
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (fullTextField.evaluate().isNotEmpty) break;
    }
    expect(fullTextField, findsOneWidget,
        reason: 'full-text search page must be open');
    await tester.enterText(fullTextField.first, '相对路径');
    // Directly probe the Rust search API to separate UI from core issues.
    final probe = await rust.searchBooks(query: '相对路径', limit: null);
    debugPrint('searchBooks probe: error=${probe.error} '
        'hits=${probe.hits.map((h) => '${h.bookId}:p${h.page}').join(',')}');
    // The hit is 0-indexed page 8 -> displayed as 第 9 页.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.textContaining('第 9 页').evaluate().isNotEmpty) break;
    }
    expect(find.textContaining('第 9 页'), findsWidgets,
        reason: 'search must hit page 9 of the scanned book');

    await tester.tap(find.textContaining('第 9 页').first);
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final viewer = container().read(viewerProvider);
      if (!viewer.loading && viewer.book?.id == 8) break;
    }
    final viewer2 = container().read(viewerProvider);
    debugPrint('jump: book=${viewer2.book?.id} page=${viewer2.currentPage}');
    expect(viewer2.currentPage, 9,
        reason: 'search jump must land on the hit page (0-indexed 8)');

    // The jumped page (0-indexed 8) is a scanned page: it must end up with a
    // scan state -- prompt (never scanned) or success (cached from an
    // earlier session) -- never blank.
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      final phase = container().read(scanStateProvider).of(8)?.phase;
      if (phase == ScanPhase.prompt || phase == ScanPhase.success) break;
    }
    scan = container().read(scanStateProvider);
    final phase = scan.of(8)?.phase;
    debugPrint('scan after jump: '
        '${scan.pages.entries.map((e) => '${e.key}:${e.value.phase.name}').join(', ')}');
    expect(phase == ScanPhase.prompt || phase == ScanPhase.success, isTrue,
        reason: 'jumped scanned page must have a scan state, got $phase');
  });
}
