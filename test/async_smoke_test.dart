import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/annotation.dart';

import 'helpers/smoke_helpers.dart';

/// Smoke test for the Rust async pipeline: verifies that open_book and
/// render_page (async FRB functions) complete without blocking/hanging, and
/// that the M3 annotation CRUD + export commands round-trip through SQLite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // A self-contained sample PDF for the whole suite.
    File('/tmp/test.pdf')
        .writeAsStringSync(buildMinimalPdf('Dummy PDF for RBWA smoke tests'));
    await initIsolatedCore();
  });

  test('rust async pdf pipeline completes', () async {
    // Async pdfium open (runs on FRB worker thread).
    final open = await rust.openBook(storedPath: '/tmp/test.pdf');
    expect(open.error, isNull, reason: 'open_book: ${open.error}');
    expect(open.pageCount, greaterThanOrEqualTo(1));

    // Async render (runs on FRB worker thread).
    final r = await rust.renderPage(
      bookId: 1,
      page: 0,
      zoom: 1.0,
      dpiScale: 1.0,
    );
    expect(r.error, isNull, reason: 'render_page: ${r.error}');
    expect(r.width, greaterThan(0));
    expect(r.height, greaterThan(0));
    expect(r.rgba.length, r.width * r.height * 4);

    await rust.closeBook();
    // ignore: avoid_print
    print('PIPELINE_OK: ${r.width}x${r.height}');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('rust annotation CRUD + export round-trip', () async {
    // Import the sample PDF to get a real book row (FK target).
    final imported = await rust.importBook(path: '/tmp/test.pdf');
    expect(imported.error, isNull,
        reason: 'import_book: ${imported.error}');
    final bookId = imported.book!.id;

    // create: highlight with one normalized rect.
    final created = await rust.createAnnotation(
      bookId: bookId,
      page: 2,
      kind: TextAnnotationKind.highlight,
      text: 'selected words',
      content: null,
      rects: const [NormRect(x: 0.1, y: 0.2, w: 0.5, h: 0.03)],
      color: '#abcdef',
    );
    expect(created.error, isNull, reason: 'create: ${created.error}');
    expect(created.id, greaterThan(0));

    // create: note with content.
    final note = await rust.createAnnotation(
      bookId: bookId,
      page: 2,
      kind: TextAnnotationKind.note,
      text: 'phrase',
      content: 'my note',
      rects: const [NormRect(x: 0.1, y: 0.25, w: 0.4, h: 0.03)],
      color: null,
    );
    expect(note.error, isNull, reason: 'create note: ${note.error}');

    // list: two rows, ordered by page.
    final listed = await rust.listAnnotations(bookId: bookId);
    expect(listed, hasLength(2));
    expect(listed[0].kind, TextAnnotationKind.highlight);
    expect(listed[0].text, 'selected words');
    expect(listed[0].rects.single.w, closeTo(0.5, 1e-9));

    // update note content.
    expect(await rust.updateAnnotationContent(
      annotationId: note.id,
      content: 'edited note',
    ), 1);

    // exports include both rows.
    final md = await rust.exportAnnotationsMarkdown(bookId: bookId);
    expect(md.error, isNull, reason: 'md: ${md.error}');
    expect(md.content, contains('# 阅读标注'));
    expect(md.content, contains('## 第 3 页'));
    expect(md.content, contains('🔆 高亮：selected words'));
    expect(md.content, contains('📝 笔记：phrase'));

    final json = await rust.exportAnnotationsJson(bookId: bookId);
    expect(json.error, isNull, reason: 'json: ${json.error}');
    expect(json.content, contains('"kind": "highlight"'));
    expect(json.content, contains('"text": "selected words"'));
    expect(json.content, contains('"rects"'));

    // delete both, list empties.
    expect(await rust.deleteAnnotation(annotationId: created.id), 1);
    expect(await rust.deleteAnnotation(annotationId: note.id), 1);
    expect(await rust.listAnnotations(bookId: bookId), isEmpty);

    // cleanup the imported book (cascade deletes its annotations).
    final del = await rust.deleteBook(id: bookId);
    expect(del, 1, reason: 'delete_book should succeed');
    // ignore: avoid_print
    print('ANNOTATIONS_OK');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('pdf import generates a cover thumbnail (FEATURES 2.6)', () async {
    final imported = await rust.importBook(path: '/tmp/test.pdf');
    expect(imported.error, isNull, reason: 'import: ${imported.error}');
    final book = imported.book!;

    // The import renders page 0 into covers/{id}.png and stores the path.
    final cover = book.coverPath;
    expect(cover, isNotNull, reason: 'pdf import must set cover_path');
    expect(File(cover!).existsSync(), isTrue,
        reason: 'cover file must exist on disk: $cover');
    // The file is a real PNG (magic bytes).
    final bytes = File(cover).readAsBytesSync();
    expect(bytes.length, greaterThan(8));
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);

    expect(await rust.deleteBook(id: book.id), 1);
    // ignore: avoid_print
    print('COVER_OK: $cover');
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('image book renders the image, not the previous PDF (regression)',
      () async {
    // Simulate "last opened PDF": open the sample PDF and render it.
    final pdfOpen = await rust.openBook(storedPath: '/tmp/test.pdf');
    expect(pdfOpen.error, isNull);
    final pdfRender = await rust.renderPage(
        bookId: 1, page: 0, zoom: 1.0, dpiScale: 1.0);
    expect(pdfRender.width, greaterThan(0));

    // Now open an 8x8 red PNG: the render must show the IMAGE (8x8), not
    // the PDF's first page (regression: the image pipeline used to keep
    // the previous PDF document open and rendered its page 1).
    final pngPath = '/tmp/test_image.png';
    File(pngPath).writeAsBytesSync(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAYAAADED76LAAAAEklEQVR4nGP4z8DwHx9mGBkKAMLXf4EvceABAAAAAElFTkSuQmCC'));
    final imported = await rust.importBook(path: pngPath);
    expect(imported.error, isNull, reason: 'import: ${imported.error}');
    final opened = await rust.openBook(storedPath: imported.book!.storedPath);
    expect(opened.error, isNull, reason: 'open image: ${opened.error}');
    expect(opened.pageCount, 1);

    final r = await rust.renderPage(
        bookId: imported.book!.id, page: 0, zoom: 1.0, dpiScale: 1.0);
    expect(r.error, isNull, reason: 'render image: ${r.error}');
    expect(r.width, 8, reason: 'must render the image, not the PDF');
    expect(r.height, 8);

    await rust.closeBook();
    expect(await rust.deleteBook(id: imported.book!.id), 1);
    // ignore: avoid_print
    print('IMAGE_BOOK_OK: ${r.width}x${r.height}');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
