import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/data/repositories/search_repository.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/features/search/search_page.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/book.dart';

/// Fake search backend: returns the canned hits for any query.
class _FakeSearchRepo extends SearchRepository {
  _FakeSearchRepo(this.hits);

  final List<rust.SearchHit> hits;
  int calls = 0;

  @override
  Future<rust.SearchResult> searchBooks(String query, {int? limit}) async {
    calls++;
    return rust.SearchResult(hits: hits, error: null);
  }

  @override
  Future<String> indexStatus(int bookId) async => 'ready';
}

/// Fixed books list for the result titles.
class _FakeBooksNotifier extends LibraryBooksNotifier {
  @override
  Future<List<Book>> build() async => const [
        Book(
          id: 1,
          title: '量子计算导论',
          originalPath: '/1.pdf',
          storedPath: '/1.pdf',
          fileType: BookType.pdf,
          pageCount: 10,
          favorite: false,
          categoryId: null,
          importedAt: 'now',
        ),
        Book(
          id: 2,
          title: '深度学习',
          originalPath: '/2.pdf',
          storedPath: '/2.pdf',
          fileType: BookType.pdf,
          pageCount: 8,
          favorite: false,
          categoryId: null,
          importedAt: 'now',
        ),
      ];
}

void main() {
  testWidgets('search page groups hits by book and jumps on tap', (tester) async {
    final repo = _FakeSearchRepo(const [
      rust.SearchHit(bookId: 1, page: 2, snippet: '…介绍量子计算的基础概念…'),
      rust.SearchHit(bookId: 1, page: 5, snippet: '…量子计算与经典计算…'),
      rust.SearchHit(bookId: 2, page: 0, snippet: '…深度学习框架…'),
    ]);
    final router = GoRouter(
      initialLocation: '/search',
      routes: [
        GoRoute(
          path: '/search',
          builder: (_, _) => const Scaffold(body: SearchPage()),
        ),
        GoRoute(
          path: '/reader/:bookId',
          builder: (_, _) => const Scaffold(body: Text('reader-stub')),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          searchRepositoryProvider.overrideWithValue(repo),
          libraryBooksProvider.overrideWith(_FakeBooksNotifier.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );

    // Type a query; the 300ms debounce fires the search.
    await tester.enterText(find.byType(TextField), '量子');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(repo.calls, 1);

    // Grouped by book: two headers, three page rows.
    expect(find.text('量子计算导论'), findsOneWidget);
    expect(find.text('深度学习'), findsOneWidget);
    expect(find.text('第 3 页'), findsOneWidget);
    expect(find.text('第 6 页'), findsOneWidget);
    expect(find.text('第 1 页'), findsOneWidget);

    // Tapping a hit navigates to the reader and records the jump target
    // (0-indexed page + the query for in-page highlighting).
    final container =
        ProviderScope.containerOf(tester.element(find.byType(SearchPage)));
    await tester.tap(find.text('第 6 页'));
    await tester.pumpAndSettle();
    expect(find.text('reader-stub'), findsOneWidget); // on /reader/1
    final target = container.read(searchHitProvider);
    expect(target?.bookId, 1);
    expect(target?.page, 5);
    expect(target?.query, '量子');
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty query shows the guide, no results shows empty state',
      (tester) async {
    final repo = _FakeSearchRepo(const []);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        searchRepositoryProvider.overrideWithValue(repo),
        libraryBooksProvider.overrideWith(_FakeBooksNotifier.new),
      ],
      child: const MaterialApp(home: Scaffold(body: SearchPage())),
    ));

    // Initial: guide (no search performed).
    expect(find.text('全文搜索'), findsOneWidget);
    expect(find.textContaining('输入关键词'), findsOneWidget);

    // A query with no hits -> empty state.
    await tester.enterText(find.byType(TextField), '不存在词');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.text('没有找到结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
