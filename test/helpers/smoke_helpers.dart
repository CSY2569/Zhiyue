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
