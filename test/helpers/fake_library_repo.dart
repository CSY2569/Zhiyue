import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Minimal [LibraryRepository] for tests that only need `getBook`.
class FakeLibraryRepository extends LibraryRepository {
  FakeLibraryRepository({this.book});

  final Book? book;

  /// Ids passed to [getBook], in call order.
  final requestedIds = <int>[];

  @override
  Future<Book?> getBook(int id) async {
    requestedIds.add(id);
    return book;
  }
}
