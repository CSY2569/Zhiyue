import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/progress.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine, OcrResult;

/// Fake repository: the text-layer check and the scan engine are canned
/// (the real engine is a stub until the models are installed).
class _FakeScanRepo extends ReaderRepository {
  bool hasText = false;
  bool scanFails = true;
  bool scanEmpty = false;

  @override
  Future<bool> pageHasText(int bookId, int page) async => hasText;

  @override
  Future<rust.ScanPageResult> scanPage(
          int bookId, int page, rust.OcrMode mode) async {
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
      lines: [
        OcrLine(text: '你好世界', x: 0.1, y: 0.2, w: 0.5, h: 0.03, confidence: 0.98),
      ],
      mode: 'high_precision',
      error: null,
    );
  }

  @override
  Future<OcrResult?> getPageOcr(int bookId, int page, rust.OcrMode mode) async =>
      null;
}

Book _book() => Book(
      id: 1,
      title: '扫描书',
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

ProviderContainer _container(_FakeScanRepo repo) {
  final container = ProviderContainer(overrides: [
    readerRepositoryProvider.overrideWithValue(repo),
    viewerProvider.overrideWith((ref) {
      final n = ViewerNotifier(ref);
      n.state = ViewerState(
        book: _book(),
        pageCount: 3,
        currentPage: 1,
        zoom: 1.2,
        loading: false,
      );
      return n;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Wait for the async text-layer check to land.
Future<void> _settle(ProviderContainer container, ScanPhase expect) async {
  for (var i = 0; i < 200; i++) {
    if (container.read(scanStateProvider).phase == expect) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('scan state never reached $expect: '
      '${container.read(scanStateProvider).phase}');
}

void main() {
  test('page with a text layer stays quiet (hasText)', () async {
    final repo = _FakeScanRepo()..hasText = true;
    final container = _container(repo);
    // Force the provider to build (the check runs on build).
    container.read(scanStateProvider);
    await _settle(container, ScanPhase.hasText);
  });

  test('page without a text layer offers 扫描识别 (prompt)', () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, ScanPhase.prompt);
  });

  test('scan with the stub engine surfaces the model-missing error', () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan();
    final state = container.read(scanStateProvider);
    expect(state.phase, ScanPhase.error);
    expect(state.error, contains('download_ocr_models.sh'));
  });

  test('successful scan lands in success; empty result in empty', () async {
    final repo = _FakeScanRepo()
      ..hasText = false
      ..scanFails = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, ScanPhase.prompt);

    await container.read(scanStateProvider.notifier).scan();
    expect(container.read(scanStateProvider).phase, ScanPhase.success);

    // A page the engine finds nothing on -> empty + region-OCR guidance.
    repo.scanEmpty = true;
    container.read(scanStateProvider.notifier).dismiss();
    await container.read(scanStateProvider.notifier).scan();
    expect(container.read(scanStateProvider).phase, ScanPhase.empty);
  });

  test('dismiss hides the prompt until the page changes', () async {
    final repo = _FakeScanRepo()..hasText = false;
    final container = _container(repo);
    container.read(scanStateProvider);
    await _settle(container, ScanPhase.prompt);

    container.read(scanStateProvider.notifier).dismiss();
    expect(container.read(scanStateProvider).phase, ScanPhase.dismissed);

    // Flipping the page re-runs the check (back to prompt).
    container.read(viewerProvider.notifier).setPage(2);
    await _settle(container, ScanPhase.prompt);
  });
}
