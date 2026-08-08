import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/book.dart';

export 'package:rbwa/features/reader/providers/viewer_provider.dart'
    show ViewerNotifier, ViewerState, viewerProvider;

/// A minimal [Book] row for widget tests (the generated model has no
/// copyWith, so every test file used to rebuild this 11-field literal).
Book testBook({
  int id = 1,
  String title = '测试书',
  BookType fileType = BookType.pdf,
  int pageCount = 3,
}) =>
    Book(
      id: id,
      title: title,
      originalPath: '/x.pdf',
      storedPath: '/x.pdf',
      fileType: fileType,
      pageCount: pageCount,
      coverPath: null,
      favorite: false,
      categoryId: null,
      lastOpenedAt: null,
      importedAt: 'now',
    );

/// A viewer-provider override pre-seeded with [state] -- widget tests skip
/// the async openBook flow and only need the viewer state to render.
Override seededViewer(ViewerState state) => viewerProvider.overrideWith((ref) {
      final n = ViewerNotifier(ref);
      n.state = state;
      return n;
    });

/// The standard reading-state override: [book] open on [currentPage] at a
/// non-trivial zoom, no loading / error.
Override defaultViewer({Book? book, int currentPage = 1}) => seededViewer(
      ViewerState(
        book: book ?? testBook(),
        pageCount: book?.pageCount ?? 3,
        currentPage: currentPage,
        zoom: 1.2,
        loading: false,
      ),
    );

/// Fixed category list for the rail / filter widget tests (both files used
/// to carry a private copy of this notifier).
class FakeCategoriesNotifier extends CategoriesNotifier {
  @override
  Future<List<Category>> build() async => const [
        Category(id: 1, name: '小说', sortOrder: 0, createdAt: ''),
        Category(id: 2, name: '技术', sortOrder: 0, createdAt: ''),
      ];
}
