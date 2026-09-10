import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

import 'helpers/smoke_helpers.dart';

/// Cover lifecycle (FEATURES 2.6).
///
/// Regression context: tests used to resolve `covers/{id}.png` through the
/// real app-data dir even though the DB was isolated, so deleting a test book
/// deleted the *user's* cover whenever the ids overlapped. The data dir now
/// follows the initialized DB, and `repair_covers` restores a lost file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    File('/tmp/cover.pdf').writeAsStringSync(buildMinimalPdf('Cover test'));
    await initIsolatedCore();
  });

  test('test data dir is isolated from the real app data dir', () async {
    // The isolated core must resolve its data dir under the scratch DB dir.
    final imported = await rust.importBook(path: '/tmp/cover.pdf');
    expect(imported.error, isNull, reason: '${imported.error}');
    final cover = imported.book!.coverPath;
    expect(cover, isNotNull);
    expect(cover, startsWith('/tmp/rbwa-test/'),
        reason: 'cover must live in the isolated dir, not the real one');
    expect(File(cover!).existsSync(), isTrue);
    await rust.deleteBook(id: imported.book!.id);
  });

  test('repair_covers restores a deleted cover file', () async {
    // Import a PDF, then delete its cover file behind the app's back.
    final imported = await rust.importBook(path: '/tmp/cover.pdf');
    final book = imported.book!;
    final cover = book.coverPath!;
    expect(File(cover).existsSync(), isTrue);
    File(cover).deleteSync();
    expect(File(cover).existsSync(), isFalse);

    // Repair rebuilds it from the stored copy through an independent document.
    final repaired = await rust.repairCovers();
    expect(repaired, 1);
    expect(File(cover).existsSync(), isTrue, reason: 'cover must be rebuilt');
    expect(File(cover).lengthSync(), greaterThan(0));

    // Idempotent: nothing missing now, so nothing is rebuilt.
    expect(await rust.repairCovers(), 0);

    await rust.deleteBook(id: book.id);
  });
}
