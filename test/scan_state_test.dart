import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'helpers/widget_harness.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/ocr.dart' show OcrLine, OcrResult;

import 'helpers/fake_ai_repo.dart';

/// Fake repository: the text-layer check and the scan engine are canned.
class _FakeScanRepo extends ReaderRepository {
  bool hasText = false;
  bool scanFails = true;
  bool scanEmpty = false;
  rust.OcrMode? lastMode;
  final scannedPages = <int>[];

  /// Lines a successful scan returns (default: one confident line).
  List<OcrLine> lines = const [
    OcrLine(text: '你好世界', x: 0.1, y: 0.2, w: 0.5, h: 0.03, confidence: 0.98),
  ];

  /// Cached OCR results served by [getPageOcr] (simulates earlier scans).
  final ocrCache = <int, OcrResult>{};  @override
  Future<bool> pageHasText(int bookId, int page) async => hasText;

  @override
  Future<rust.ScanPageResult> scanPage(
          int bookId, int page, rust.OcrMode mode) async {
    lastMode = mode;
    scannedPages.add(page);
    if (scanFails) {
      return rust.ScanPageResult(
        lines: const [],
        mode: 'high_precision',
        error: 'OCR 模型未安装：请运行 scripts/download_ocr_models.sh 下载模型后重试',
      );
    }
    if (scanEmpty) {
      return rust.ScanPageResult(lines: const [], mode: 'high_precision', error: null);
    }
    return rust.ScanPageResult(
      lines: lines,
      mode: 'high_precision',
      error: null,
    );
  }

  @override
  Future<OcrResult?> getPageOcr(int bookId, int page, rust.OcrMode mode) async =>
      ocrCache[page];
}

ProviderContainer _container(_FakeScanRepo repo, {FakeAiRepo? aiRepo}) {
  final container = ProviderContainer(overrides: [
    readerRepositoryProvider.overrideWithValue(repo),
    if (aiRepo != null) aiRepositoryProvider.overrideWithValue(aiRepo),
    defaultViewer(book: testBook(title: '扫描书')),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Wait for the async text-layer check of [page0] to land.
Future<void> _settle(ProviderContainer container, int page0,
    ScanPhase expect) async {
  for (var i = 0; i < 200; i++) {
    if (container.read(scanStateProvider).of(page0)?.phase == expect) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('scan state of page $page0 never reached $expect: '
      '${container.read(scanStateProvider).of(page0)?.phase}');
}

void main() {
  test('page with a text layer stays quiet (hasText)', () async {
    final repo = _FakeScanRepo()..hasText = true;
    final container = _container(repo);
    // Force the provider to build (the check runs on build).
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.hasText);
  });

  test('page without a text layer offers 扫描识别 (prompt)', () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);
  });

  test('both halves of a spread are detected independently', () async {
    // currentPage = 1: pages 0 and 1 are both in view (single or double
    // mode) -- the right neighbour must get its own prompt too, so scanned
    // books can be selected/annotated on the right page of a spread.
    final repo = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);
    await _settle(container, 1, ScanPhase.prompt);

    // Each page scans independently: scanning the right page affects only it.
    await container.read(scanStateProvider.notifier).scan(1);
    expect(repo.scannedPages, [1]);
    expect(container.read(scanStateProvider).of(1)!.phase, ScanPhase.success);
    expect(container.read(scanStateProvider).of(0)!.phase, ScanPhase.prompt);
  });

  test('scan with the stub engine surfaces the model-missing error', () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan(0);
    final state = container.read(scanStateProvider).of(0)!;
    expect(state.phase, ScanPhase.error);
    expect(state.error, contains('download_ocr_models.sh'));
  });

  test('successful scan lands in success; empty result in empty', () async {
    final repo = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan(0);
    expect(container.read(scanStateProvider).of(0)!.phase, ScanPhase.success);

    // A page the engine finds nothing on -> empty + region-OCR guidance.
    repo.scanEmpty = true;
    container.read(scanStateProvider.notifier).dismiss(0);
    await container.read(scanStateProvider.notifier).scan(0);
    expect(container.read(scanStateProvider).of(0)!.phase, ScanPhase.empty);
  });

  test('dismiss hides the prompt for that page until the page changes',
      () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);

    container.read(scanStateProvider.notifier).dismiss(0);
    expect(container.read(scanStateProvider).of(0)!.phase, ScanPhase.dismissed);

    // The right neighbour's prompt is untouched (per-page state).
    expect(container.read(scanStateProvider).of(1)!.phase, ScanPhase.prompt);

    // Flipping the page checks the new pages in view (page 2 gets a prompt).
    container.read(viewerProvider.notifier).setPage(2);
    await _settle(container, 2, ScanPhase.prompt);
  });

  test('scan follows the configured OCR model set (7.1.9)', () async {
    final repo = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false;
    final aiRepo = FakeAiRepo()..ocrMode = 'fast';
    final container = _container(repo, aiRepo: aiRepo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan(0);
    expect(container.read(scanStateProvider).of(0)!.phase, ScanPhase.success);
    expect(repo.lastMode, rust.OcrMode.fast);

    // Default (no config override): high precision.
    final repo2 = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false;
    final container2 = _container(repo2);
    container2.read(scanStateProvider);
    await _settle(container2, 0, ScanPhase.prompt);
    await container2.read(scanStateProvider.notifier).scan(0);
    expect(repo2.lastMode, rust.OcrMode.highPrecision);
  });

  test('pages scanned in an earlier session do not nag again (7.1.4)',
      () async {
    // Page 0 has a cached OCR result (scanned before the restart); page 1
    // has none. The prompt must not reappear for page 0.
    final repo = _FakeScanRepo()
      ..hasText = false
      ..ocrCache[0] = OcrResult(
          lines: const [
            OcrLine(
                text: '已有缓存',
                x: 0.1,
                y: 0.1,
                w: 0.5,
                h: 0.03,
                confidence: 0.95),
          ],
          mode: 'high_precision',
      );
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.success);
    await _settle(container, 1, ScanPhase.prompt);
    // The cached page carries its low-confidence count like a fresh scan.
    expect(container.read(scanStateProvider).of(0)!.lowConfidence, 0);
  });

  test('success counts low-confidence lines for review (7.1.6)', () async {
    final repo = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false
      ..lines = const [
        OcrLine(text: '清晰', x: 0.1, y: 0.1, w: 0.5, h: 0.03, confidence: 0.98),
        OcrLine(text: '模糊', x: 0.1, y: 0.2, w: 0.5, h: 0.03, confidence: 0.62),
        OcrLine(text: '边界', x: 0.1, y: 0.3, w: 0.5, h: 0.03, confidence: 0.8),
      ];
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, 0, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan(0);
    final state = container.read(scanStateProvider).of(0)!;
    expect(state.phase, ScanPhase.success);
    // 0.62 < 0.8 flagged; 0.8 is exactly at the threshold, not flagged.
    expect(state.lowConfidence, 1);
  });

  test('book opened at a middle page checks the pages in view (regression)',
      () async {
    // Opening restores / jumps straight to page 5: pages 4 and 5 (the left
    // and right half of the spread) must still get their scan prompts.
    final repo = _FakeScanRepo()..hasText = false;
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(repo),
      defaultViewer(book: testBook(pageCount: 10), currentPage: 5),
    ]);
    addTearDown(container.dispose);
    container.read(scanStateProvider);
    await _settle(container, 4, ScanPhase.prompt);
    await _settle(container, 5, ScanPhase.prompt);
  });
}
