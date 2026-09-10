import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

import 'helpers/smoke_helpers.dart';

/// Regression test for the document outline tree (FEATURES 3.4.2).
///
/// pdfium's bookmark iterator walks the whole tree depth-first, so building
/// the top-level list from it makes every descendant appear twice: once as a
/// top-level entry and again inside its parent's children. Each bookmark must
/// appear exactly once, nested under its real parent.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    File('/tmp/outline.pdf').writeAsStringSync(buildPdfWithOutline());
    await initIsolatedCore();
  });

  test('outline nests children instead of duplicating them at top level',
      () async {
    final open = await rust.openBook(storedPath: '/tmp/outline.pdf');
    expect(open.error, isNull, reason: 'open_book: ${open.error}');
    expect(open.hasOutline, isTrue, reason: 'fixture should carry /Outlines');

    final result = await rust.getOutline(bookId: 1);
    expect(result.error, isNull, reason: 'get_outline: ${result.error}');

    final entries = result.entries;
    // Exactly one top-level chapter -- NOT one entry per bookmark node.
    expect(entries.length, 1,
        reason: 'top level should be Chapter 1 only, got '
            '${entries.map((e) => e.title).toList()}');
    expect(entries.single.title, 'Chapter 1');
    expect(entries.single.page, greaterThanOrEqualTo(0));

    // The two sections live under the chapter, each exactly once.
    final children = entries.single.children;
    expect(children.map((c) => c.title).toList(), ['Section 1.1', 'Section 1.2']);
    for (final child in children) {
      expect(child.children, isEmpty, reason: 'sections have no children');
      expect(child.page, greaterThanOrEqualTo(0));
    }

    // The duplication bug showed the sections as top-level siblings too;
    // guard against any repeated top-level title.
    final titles = entries.map((e) => e.title).toList();
    expect(titles.toSet().length, titles.length,
        reason: 'duplicate top-level entries: $titles');

    await rust.closeBook();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
