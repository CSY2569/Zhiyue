import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/frb_generated.dart';

/// Builds a minimal but valid one-page PDF (Helvetica text) with a correct
/// xref table, so smoke tests do not depend on external sample files.
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

/// Isolated test database under the system temp (`/tmp` on Linux,
/// `%TEMP%` on Windows), so the smoke tests never touch the user's data.
final String testTmpDir = p.join(Directory.systemTemp.path, 'rbwa-test');
final String testDbPath = p.join(testTmpDir, 'rbwa.db');

/// Absolute path of a scratch file directly under the system temp.
String tmpFile(String name) => p.join(Directory.systemTemp.path, name);

/// Builds a minimal single-page PDF carrying a two-level outline tree:
///
///   Chapter 1
///     ├─ Section 1.1
///     └─ Section 1.2
///
/// Used to regression-test the outline (bookmark) tree: pdfium's bookmark
/// iterator walks the whole tree, so a naive top-level build makes each
/// section appear both as a sibling of the chapter and as its child.
String buildPdfWithOutline() {
  final stream = 'BT /F1 24 Tf 72 770 Td (Outline test) Tj ET';
  final objects = <String>[
    // 1 Catalog (references the outline root)
    '<< /Type /Catalog /Pages 2 0 R /Outlines 6 0 R >>',
    // 2 Pages
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    // 3 Page
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
        '/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
    // 4 Contents stream
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    // 5 Font
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    // 6 Outline root: a single top-level item (Chapter 1)
    '<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 3 >>',
    // 7 Chapter 1: carries the two sections as children
    '<< /Title (Chapter 1) /Parent 6 0 R /Dest [3 0 R /Fit] '
        '/First 8 0 R /Last 9 0 R /Count 2 >>',
    // 8 Section 1.1 (first sibling)
    '<< /Title (Section 1.1) /Parent 7 0 R /Dest [3 0 R /Fit] /Next 9 0 R >>',
    // 9 Section 1.2 (second sibling)
    '<< /Title (Section 1.2) /Parent 7 0 R /Dest [3 0 R /Fit] /Prev 8 0 R >>',
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

/// Init RustLib + a fresh isolated test DB: every run starts clean, so the
/// integration smoke tests never touch the user's real data.
Future<void> initIsolatedCore() async {
  await RustLib.init();
  final dir = Directory(testTmpDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final init = await rust.initCoreWithDbPath(dbPath: testDbPath);
  expect(init.ok, true, reason: 'core init: ${init.error}');
}
