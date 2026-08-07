import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/frb_generated.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Builds a minimal but valid one-page PDF (Helvetica text) with a correct
/// xref table, so the smoke test does not depend on external sample files.
String buildMinimalPdf(String text) {
  final stream = 'BT /F1 24 Tf 72 770 Td ($text) Tj ET';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
  ];
  final sb = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(sb.length);
    sb.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xrefPos = sb.length;
  sb.write('xref\n0 ${objects.length + 1}\n');
  sb.write('0000000000 65535 f \n');
  for (final off in offsets) {
    sb.write('${off.toString().padLeft(10, '0')} 00000 n \n');
  }
  sb.write('trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefPos\n%%EOF\n');
  return sb.toString();
}

/// Isolated test database: every run starts from a fresh DB under /tmp, so
/// integration tests never touch the user's real data.
const _testDbPath = '/tmp/rbwa-test/rbwa.db';

Future<void> _initIsolatedDb() async {
  await RustLib.init();
  final dir = Directory('/tmp/rbwa-test');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final init = await rust.initCoreWithDbPath(dbPath: _testDbPath);
  expect(init.ok, true, reason: 'core init: ${init.error}');
}

/// Smoke test for the Rust async pipeline: verifies that open_book and
/// render_page (async FRB functions) complete without blocking/hanging, and
/// that the M3 annotation CRUD + export commands round-trip through SQLite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // A self-contained sample PDF for the whole suite.
    File('/tmp/test.pdf')
        .writeAsStringSync(buildMinimalPdf('Dummy PDF for RBWA smoke tests'));
    await _initIsolatedDb();
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
}
