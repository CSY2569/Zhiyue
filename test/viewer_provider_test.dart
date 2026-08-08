import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Fake library: returns the canned book for [getBook].
class _FakeLibraryRepo extends LibraryRepository {
  _FakeLibraryRepo(this.book);
  final Book book;

  @override
  Future<Book?> getBook(int id) async => book;
}

/// Fake reader repository: records openBook calls, returns a 1-page doc.
class _FakeReaderRepo extends ReaderRepository {
  final opened = <String>[];

  @override
  Future<rust.OpenBookResult> openBook(String storedPath) async {
    opened.add(storedPath);
    return rust.OpenBookResult(pageCount: 1, hasOutline: false, error: null);
  }

  @override
  Future<ReadingProgress?> getProgress(int bookId) async => null;
}

Book _book(BookType type) => Book(
      id: 1,
      title: type == BookType.image ? '图片' : '文档',
      originalPath: '/src',
      storedPath: type == BookType.image ? '/data/img.png' : '/data/doc.pdf',
      fileType: type,
      pageCount: type == BookType.image ? 1 : 3,
      coverPath: null,
      favorite: false,
      categoryId: null,
      lastOpenedAt: null,
      importedAt: 'now',
    );

void main() {
  test('opening an image book calls Rust open_book (regression: it used to '
      'skip it, leaving the previous PDF open and rendering its page 1)',
      () async {
    final reader = _FakeReaderRepo();
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(reader),
      libraryRepositoryProvider
          .overrideWithValue(_FakeLibraryRepo(_book(BookType.image))),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(viewerProvider.notifier);
    await notifier.openBook(1);

    // The image book must go through the Rust open pipeline (which routes
    // to the image decoder and switches the render flag).
    expect(reader.opened, ['/data/img.png']);
    final state = container.read(viewerProvider);
    expect(state.book?.fileType, BookType.image);
    expect(state.pageCount, 1);
    expect(state.error, isNull);
  });

  test('opening a PDF book calls Rust open_book too', () async {
    final reader = _FakeReaderRepo();
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(reader),
      libraryRepositoryProvider
          .overrideWithValue(_FakeLibraryRepo(_book(BookType.pdf))),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(viewerProvider.notifier);
    await notifier.openBook(1);
    expect(reader.opened, ['/data/doc.pdf']);
    expect(container.read(viewerProvider).error, isNull);
  });
}
