import 'dart:typed_data';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/progress.dart' show ReadingProgress;
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox, OutlineEntry;

/// Configurable in-memory [ReaderRepository] for widget/unit tests.
///
/// Tests that need a call counter or custom payload set a field; everything
/// else falls back to a deterministic, Rust-free default (one A4 page).
/// Stateful flows (OCR scan lifecycle, image marks) keep their bespoke fakes
/// because their assertions are about that state machine, not the transport.
class FakeReaderRepository extends ReaderRepository {
  FakeReaderRepository({
    this.openBookResult =
        const rust.OpenBookResult(pageCount: 1, hasOutline: false, error: null),
    this.progress,
    this.charBoxes = const [],
    this.outlineEntries = const [],
    this.hasText = false,
    this.pageWidth = 400,
    this.pageHeight = 565,
  });

  final rust.OpenBookResult openBookResult;
  final ReadingProgress? progress;
  final List<CharBox> charBoxes;
  final List<OutlineEntry> outlineEntries;
  final bool hasText;
  final int pageWidth;
  final int pageHeight;

  /// Paths passed to [openBook], in call order.
  final opened = <String>[];

  /// Number of [renderThumbnail] calls (cache-hit assertions).
  int thumbnailCalls = 0;

  rust.PageRenderResult _bitmap() => rust.PageRenderResult(
        width: pageWidth,
        height: pageHeight,
        rgba: Uint8List(pageWidth * pageHeight * 4),
        error: null,
      );

  @override
  Future<rust.OpenBookResult> openBook(String storedPath) async {
    opened.add(storedPath);
    return openBookResult;
  }

  @override
  Future<ReadingProgress?> getProgress(int bookId) async => progress;

  @override
  Future<rust.PageRenderResult> renderPage(
    int bookId,
    int page,
    double zoom,
    double dpiScale,
  ) async =>
      _bitmap();

  @override
  Future<rust.PageRenderResult> renderThumbnail(
    int bookId,
    int page,
    int maxSize,
  ) async {
    thumbnailCalls++;
    return _bitmap();
  }

  @override
  Future<rust.CharBoxResult> extractText(int bookId, int page) async =>
      rust.CharBoxResult(boxes: charBoxes, error: null);

  @override
  Future<bool> pageHasText(int bookId, int page) async => hasText;

  @override
  Future<rust.OutlineResult> getOutline(int bookId) async =>
      rust.OutlineResult(entries: outlineEntries, error: null);
}
