import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine, OcrResult;

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_reader_repo.dart';
import 'helpers/widget_harness.dart';

/// Image books / scanned PDF pages have no native text layer, so
/// `extractText` returns nothing and the cache must fall back to the OCR
/// result -- otherwise selection simply never works on them. Rust-free: the
/// fake serves both halves.
void main() {
  test('a page with no text layer falls back to the cached OCR lines',
      () async {
    final fake = FakeReaderRepository(charBoxes: const [])
      ..ocrResult = const OcrResult(
        mode: 'high_precision',
        lines: [
          OcrLine(
            text: '扫描出来的一行',
            x: 0.10,
            y: 0.20,
            w: 0.50,
            h: 0.03,
            confidence: 0.95,
          ),
        ],
      );

    final container = ProviderContainer(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(fake),
        aiRepositoryProvider.overrideWithValue(FakeAiRepo()),
      ],
    );
    addTearDown(container.dispose);

    final boxes =
        await container.read(charBoxCacheProvider.notifier).getOrFetch(1, 0);

    expect(boxes, hasLength(1));
    // One whole-line box: per-character positions are derived later by
    // TextPainter, not synthesized here.
    expect(boxes.single.char, '扫描出来的一行');
    expect(boxes.single.x, closeTo(0.10, 1e-9));
    expect(boxes.single.w, closeTo(0.50, 1e-9));
  });
}
