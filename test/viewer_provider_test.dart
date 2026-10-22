import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';

import 'helpers/fake_library_repo.dart';
import 'helpers/fake_reader_repo.dart';

/// Fake reader repository: records openBook calls, returns a 1-page doc.
FakeReaderRepository _reader() => FakeReaderRepository(
      openBookResult:
          const rust.OpenBookResult(pageCount: 1, hasOutline: false, error: null),
    );

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
    final reader = _reader();
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(reader),
      libraryRepositoryProvider
          .overrideWithValue(FakeLibraryRepository(book: _book(BookType.image))),
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
    final reader = _reader();
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(reader),
      libraryRepositoryProvider
          .overrideWithValue(FakeLibraryRepository(book: _book(BookType.pdf))),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(viewerProvider.notifier);
    await notifier.openBook(1);
    expect(reader.opened, ['/data/doc.pdf']);
    expect(container.read(viewerProvider).error, isNull);
  });

  test('a 0-page document opens instead of throwing on clamp', () async {
    // clamp(1, 0) throws (lower > upper); the book must still open so the
    // reader can show its own "无页面" state rather than an error banner.
    final reader = FakeReaderRepository(
      openBookResult:
          const rust.OpenBookResult(pageCount: 0, hasOutline: false, error: null),
    );
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(reader),
      libraryRepositoryProvider
          .overrideWithValue(FakeLibraryRepository(book: _book(BookType.pdf))),
    ]);
    addTearDown(container.dispose);

    await container.read(viewerProvider.notifier).openBook(1);
    final state = container.read(viewerProvider);
    expect(state.error, isNull);
    expect(state.pageCount, 0);
    expect(state.loading, isFalse);

    // Page mutations must be no-ops, not throws.
    expect(() => container.read(viewerProvider.notifier).setPage(3),
        returnsNormally);
    expect(container.read(viewerProvider).currentPage, 1);
  });

  test('a superseded openBook never overwrites the newer book', () async {
    // Book 1 renders SLOWLY; opening book 2 finishes first. Book 1's chain
    // then resumes and must bail out instead of adopting its state.
    final slow = _SlowReaderRepository();
    final container = ProviderContainer(overrides: [
      readerRepositoryProvider.overrideWithValue(slow),
      libraryRepositoryProvider.overrideWithValue(_PerIdLibrary()),
    ]);
    addTearDown(container.dispose);

    final notifier = container.read(viewerProvider.notifier);
    final first = notifier.openBook(1);
    final second = notifier.openBook(2);
    await second;
    slow.release();
    await first;

    final state = container.read(viewerProvider);
    expect(state.book?.id, 2);
    expect(state.pageCount, slow.pageCountFor(2));
    expect(state.error, isNull);
  });
}

/// Returns a distinct book per id, so a superseded chain is detectable.
class _PerIdLibrary extends LibraryRepository {
  @override
  Future<Book?> getBook(int id) async => Book(
        id: id,
        title: '书 $id',
        originalPath: '/src$id',
        storedPath: '/data/doc$id.pdf',
        fileType: BookType.pdf,
        pageCount: 3,
        coverPath: null,
        favorite: false,
        categoryId: null,
        lastOpenedAt: null,
        importedAt: 'now',
      );
}

/// Reader fake that holds the open of book 1 (path `/data/doc1.pdf`) until
/// the test releases it.
class _SlowReaderRepository extends FakeReaderRepository {
  _SlowReaderRepository()
      : super(
          openBookResult: const rust.OpenBookResult(
            pageCount: 3,
            hasOutline: false,
            error: null,
          ),
        );

  final _gate = Completer<void>();

  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  int pageCountFor(int bookId) => 3;

  @override
  Future<rust.OpenBookResult> openBook(String storedPath) async {
    if (storedPath == '/data/doc1.pdf') await _gate.future;
    return super.openBook(storedPath);
  }
}
