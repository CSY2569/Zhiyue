import 'dart:typed_data';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/ocr.dart' show OcrLine, OcrResult;
import 'package:rbwa/src/rust/models/annotation.dart'
    show ImageAnnotation, ImageAnnotationKind, NormRect, TextAnnotation, TextAnnotationKind;
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

  // ---------------------------------------------------------------------
  // Remaining transport methods.
  //
  // Every FFI-reaching method is overridden on purpose: a fake that inherits
  // the real implementation sends the call into the Rust core, so a test
  // either loads the .so or fails with an unrelated FFI error far from the
  // assertion. Observable behaviour goes into fields instead.
  // ---------------------------------------------------------------------

  /// Cached OCR lines returned by [getPageOcr] / [updatePageOcrLines].
  OcrResult? ocrResult;

  /// Overrides recorded by [saveOutlineOverride], in call order.
  final outlineSaves = <Map<String, Object?>>[];

  /// Number of [resetOutline] calls.
  int outlineResets = 0;

  @override
  Future<int> saveOutlineOverride({
    required int bookId,
    required String entryKey,
    String? parentKey,
    String? title,
    int? page,
    int? orderIndex,
    bool hidden = false,
  }) async {
    outlineSaves.add({
      'entryKey': entryKey,
      'parentKey': parentKey,
      'title': title,
      'page': page,
      'hidden': hidden,
    });
    return 1;
  }

  @override
  Future<int> deleteOutlineOverride(int bookId, String entryKey) async => 1;

  @override
  Future<int> resetOutline(int bookId) async {
    outlineResets++;
    return 1;
  }

  @override
  Future<int> saveProgress(
    int bookId,
    int page,
    double zoom,
    String viewMode,
  ) async => 1;

  @override
  Future<List<TextAnnotation>> listAnnotations(int bookId) async => const [];

  @override
  Future<rust.AnnotationCreateResult> createAnnotation({
    required int bookId,
    required int page,
    required TextAnnotationKind kind,
    String? text,
    String? content,
    required List<NormRect> rects,
    String? color,
    String source = 'original',
  }) async => const rust.AnnotationCreateResult(id: 1, error: null);

  @override
  Future<int> updateAnnotationContent(int annotationId, String? content) async => 1;

  @override
  Future<int> deleteAnnotation(int annotationId) async => 1;

  @override
  Future<rust.ExportResult> exportAnnotationsMarkdown(int bookId) async =>
      const rust.ExportResult(content: '', error: null);

  @override
  Future<rust.ExportResult> exportAnnotationsJson(int bookId) async =>
      const rust.ExportResult(content: '', error: null);

  @override
  Future<List<ImageAnnotation>> listImageAnnotations(int bookId) async =>
      const [];

  @override
  Future<rust.ImageMarkCreateResult> createImageAnnotation({
    required int bookId,
    required int page,
    required ImageAnnotationKind kind,
    required double x,
    required double y,
    double? w,
    double? h,
    required double rotation,
    required String payload,
    required String style,
  }) async => const rust.ImageMarkCreateResult(id: 1, error: null);

  @override
  Future<int> updateImageAnnotation({
    required int annotationId,
    required double x,
    required double y,
    double? w,
    double? h,
    required double rotation,
    required String payload,
    required String style,
  }) async => 1;

  @override
  Future<int> deleteImageAnnotation(int annotationId) async => 1;

  @override
  Future<OcrResult?> getPageOcr(int bookId, int page, rust.OcrMode mode) async =>
      ocrResult;

  @override
  Future<rust.ScanPageResult> scanPage(
    int bookId,
    int page,
    rust.OcrMode mode,
  ) async {
    final lines = ocrResult?.lines ?? const <OcrLine>[];
    return rust.ScanPageResult(
      lines: lines,
      // The generated `asStr()` binding returns void, so mirror the wire value
      // from the enum name (`highPrecision` -> `high_precision`).
      mode: mode.name == 'fast' ? 'fast' : 'high_precision',
      error: null,
    );
  }

  @override
  Future<OcrResult?> updatePageOcrLines(
    int bookId,
    int page,
    rust.OcrMode mode,
    List<({int lineIndex, String text})> edits,
  ) async => ocrResult;
}
