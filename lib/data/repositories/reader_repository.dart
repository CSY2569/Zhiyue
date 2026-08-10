import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/annotation.dart';
import 'package:rbwa/src/rust/models/progress.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrResult;

/// Wrapper around the FRB-generated Rust bindings for the reader / PDF /
/// image / OCR pipeline (FEATURES §3, §5, §7).
///
/// This is the only place the reader UI layer touches `lib/src/rust/*`
/// directly (ARCHITECTURE §1). Upper layers (providers, widgets) depend on
/// this repository, keeping the FFI boundary narrow.
class ReaderRepository {
  /// Open a book's PDF for reading. Must precede render/outline calls.
  Future<rust.OpenBookResult> openBook(String storedPath) =>
      rust.openBook(storedPath: storedPath);

  /// Render a page (0-indexed) to RGBA pixels for texture display.
  Future<rust.PageRenderResult> renderPage(
    int bookId,
    int page,
    double zoom,
    double dpiScale,
  ) =>
      rust.renderPage(
        bookId: bookId,
        page: page,
        zoom: zoom,
        dpiScale: dpiScale,
      );

  /// Render a small thumbnail for the sidebar.
  Future<rust.PageRenderResult> renderThumbnail(
    int bookId,
    int page,
    int maxSize,
  ) =>
      rust.renderThumbnail(
        bookId: bookId,
        page: page,
        maxSize: maxSize,
      );

  /// Fetch the document outline (table of contents).
  Future<rust.OutlineResult> getOutline(int bookId) =>
      rust.getOutline(bookId: bookId);

  /// Load the saved reading position for a book.
  Future<ReadingProgress?> getProgress(int bookId) =>
      rust.getProgress(bookId: bookId);

  /// Save the reading position (upsert).
  Future<int> saveProgress(int bookId, int page, double zoom, String viewMode) =>
      rust.saveProgress(
        bookId: bookId,
        page: page,
        zoom: zoom,
        viewMode: viewMode,
      );

  // --- M3: text selection & annotations (FEATURES §4) -----------------------

  /// Per-character boxes of a page (0-indexed) for selection hit-testing.
  Future<rust.CharBoxResult> extractText(int bookId, int page) =>
      rust.extractText(bookId: bookId, page: page);

  /// All annotations of a book, ordered by page.
  Future<List<TextAnnotation>> listAnnotations(int bookId) =>
      rust.listAnnotations(bookId: bookId);

  /// Create a mark / note; the result carries the new row id.
  Future<rust.AnnotationCreateResult> createAnnotation({
    required int bookId,
    required int page,
    required TextAnnotationKind kind,
    String? text,
    String? content,
    required List<NormRect> rects,
    String? color,
  }) =>
      rust.createAnnotation(
        bookId: bookId,
        page: page,
        kind: kind,
        text: text,
        content: content,
        rects: rects,
        color: color,
      );

  /// Update a note's body text.
  Future<int> updateAnnotationContent(int annotationId, String? content) =>
      rust.updateAnnotationContent(
        annotationId: annotationId,
        content: content,
      );

  /// Delete an annotation by id.
  Future<int> deleteAnnotation(int annotationId) =>
      rust.deleteAnnotation(annotationId: annotationId);

  /// Markdown export for a book (FEATURES 4.5.2).
  Future<rust.ExportResult> exportAnnotationsMarkdown(int bookId) =>
      rust.exportAnnotationsMarkdown(bookId: bookId);

  /// Pretty JSON export for a book (FEATURES 4.5.3).
  Future<rust.ExportResult> exportAnnotationsJson(int bookId) =>
      rust.exportAnnotationsJson(bookId: bookId);

  // --- M5: image-layer marks (FEATURES §5) ----------------------------------

  /// All image-layer marks of a book, ordered by page.
  Future<List<ImageAnnotation>> listImageAnnotations(int bookId) =>
      rust.listImageAnnotations(bookId: bookId);

  /// Create an image-layer mark; the result carries the new row id.
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
  }) =>
      rust.createImageAnnotation(
        bookId: bookId,
        page: page,
        kind: kind,
        x: x,
        y: y,
        w: w,
        h: h,
        rotation: rotation,
        payload: payload,
        style: style,
      );

  /// Update an image-layer mark (position / payload / style).
  Future<int> updateImageAnnotation({
    required int annotationId,
    required double x,
    required double y,
    double? w,
    double? h,
    required double rotation,
    required String payload,
    required String style,
  }) =>
      rust.updateImageAnnotation(
        annotationId: annotationId,
        x: x,
        y: y,
        w: w,
        h: h,
        rotation: rotation,
        payload: payload,
        style: style,
      );

  /// Delete an image-layer mark by id.
  Future<int> deleteImageAnnotation(int annotationId) =>
      rust.deleteImageAnnotation(annotationId: annotationId);

  // --- M5: full-page OCR (FEATURES §7) --------------------------------------

  /// Whether a page has a text layer (empty -> scanned / image page).
  Future<bool> pageHasText(int bookId, int page) =>
      rust.pageHasText(bookId: bookId, page: page);

  /// The cached scan result for a page (null when not scanned yet).
  Future<OcrResult?> getPageOcr(int bookId, int page, rust.OcrMode mode) =>
      rust.getPageOcr(bookId: bookId, page: page, mode: mode);

  /// Full-page OCR scan (original resolution; cached per page+mode).
  Future<rust.ScanPageResult> scanPage(int bookId, int page, rust.OcrMode mode) =>
      rust.scanPage(bookId: bookId, page: page, mode: mode);

  /// Apply manual corrections to a page's cached OCR result (7.1.7): each
  /// [edits] entry replaces the text of one recognized line; the updated
  /// result is persisted and re-indexed for full-text search.
  Future<OcrResult?> updatePageOcrLines(
    int bookId,
    int page,
    rust.OcrMode mode,
    List<rust.OcrLineEdit> edits,
  ) =>
      rust.updatePageOcrLines(
        bookId: bookId,
        page: page,
        mode: mode,
        edits: edits,
      );
}

/// Riverpod provider for the singleton [ReaderRepository].
final readerRepositoryProvider = Provider<ReaderRepository>((ref) {
  return ReaderRepository();
});
