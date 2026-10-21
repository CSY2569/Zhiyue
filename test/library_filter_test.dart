import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'helpers/widget_harness.dart';
import 'package:rbwa/features/library/widgets/category_rail.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Fixed book list for the filtered-books tests (one PDF, one image, one
/// favorite PDF in a category).
class _FakeBooksNotifier extends LibraryBooksNotifier {
  @override
  Future<List<Book>> build() async => [
        Book(
          id: 1,
          title: 'Rust 实战',
          originalPath: '/x.pdf',
          storedPath: '/x.pdf',
          fileType: BookType.pdf,
          pageCount: 3,
          favorite: false,
          categoryId: 1,
          importedAt: 'now',
        ),
        Book(
          id: 2,
          title: '封面图',
          originalPath: '/x.png',
          storedPath: '/x.png',
          fileType: BookType.image,
          pageCount: 1,
          favorite: false,
          categoryId: null,
          importedAt: 'now',
        ),
        Book(
          id: 3,
          title: '收藏的 PDF',
          originalPath: '/y.pdf',
          storedPath: '/y.pdf',
          fileType: BookType.pdf,
          pageCount: 5,
          favorite: true,
          categoryId: 2,
          importedAt: 'now',
        ),
      ];
}



void main() {
  test('书库入口互斥：PDF/图片/收藏/分类各自独立，不叠加', () {
    final n = LibraryFilterNotifier();
    n.setCategory(3);
    expect(n.state.view, LibraryView.category);
    expect(n.state.categoryId, 3);

    // Clicking PDF resets the category -- every PDF, not the category's.
    n.showPdf();
    expect(n.state.view, LibraryView.pdf);
    expect(n.state.categoryId, isNull);

    n.showImage();
    expect(n.state.view, LibraryView.image);

    n.showFavorites();
    expect(n.state.view, LibraryView.favorite);

    n.setCategory(7);
    expect(n.state.view, LibraryView.category);
    expect(n.state.categoryId, 7);
    n.showAll();
    expect(n.state.view, LibraryView.all);

    // Search is the only stacking filter: it survives view switches.
    n.setSearchQuery('rust');
    expect(n.state.isClear, isFalse);
    n.showAll();
    expect(n.state.searchQuery, 'rust');
    n.showAll();
    n.setSearchQuery('');
    expect(n.state.isClear, isTrue);
  });

  test('filteredBooksProvider 应用唯一的视图', () async {
    final container = ProviderContainer(
      overrides: [libraryBooksProvider.overrideWith(_FakeBooksNotifier.new)],
    );
    addTearDown(container.dispose);
    await container.read(libraryBooksProvider.future);
    final n = container.read(libraryFilterProvider.notifier);

    // 全部: everything.
    expect(container.read(filteredBooksProvider), hasLength(3));

    // PDF: both PDFs, regardless of category / favorite.
    n.showPdf();
    expect(
      container.read(filteredBooksProvider).map((b) => b.title).toList(),
      ['Rust 实战', '收藏的 PDF'],
    );

    // 图片: the image only.
    n.showImage();
    expect(container.read(filteredBooksProvider).single.title, '封面图');

    // 收藏: the favorite only.
    n.showFavorites();
    expect(container.read(filteredBooksProvider).single.title, '收藏的 PDF');

    // 分类 1: its books only (the favorite in category 2 is excluded).
    n.setCategory(1);
    expect(container.read(filteredBooksProvider).single.title, 'Rust 实战');

    // Search stacks on the active view.
    n.setSearchQuery('收藏');
    expect(container.read(filteredBooksProvider), isEmpty);
    n.setCategory(2);
    expect(container.read(filteredBooksProvider).single.title, '收藏的 PDF');
  });

  testWidgets('左侧栏：导航 / 文件夹 页签可切换，视图互斥', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        categoriesProvider.overrideWith(FakeCategoriesNotifier.new),
        libraryBooksProvider.overrideWith(_FakeBooksNotifier.new),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 240, child: CategoryRail(width: 240)),
        ),
      ),
    ));
    await tester.pump();
    final container =
        ProviderScope.containerOf(tester.element(find.byType(CategoryRail)));

    // The navigation tab is active by default: system views are visible and
    // the folder list is not.
    expect(find.text('所有文档'), findsOneWidget);
    expect(find.text('最近使用'), findsOneWidget);
    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('AI 对话'), findsOneWidget);
    expect(find.text('小说'), findsNothing);

    // Views are mutually exclusive.
    await tester.tap(find.text('最近使用'));
    await tester.pump();
    expect(container.read(libraryFilterProvider).view, LibraryView.recent);

    await tester.tap(find.text('PDF'));
    await tester.pump();
    expect(container.read(libraryFilterProvider).view, LibraryView.pdf);
    expect(container.read(libraryFilterProvider).categoryId, isNull);

    await tester.tap(find.text('我的收藏'));
    await tester.pump();
    expect(container.read(libraryFilterProvider).view, LibraryView.favorite);

    // The folders tab reveals user categories; selecting one switches view.
    await tester.tap(find.text('文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('小说'), findsOneWidget);
    await tester.tap(find.text('小说'));
    await tester.pump();
    expect(container.read(libraryFilterProvider).view, LibraryView.category);
    expect(container.read(libraryFilterProvider).categoryId, 1);
    expect(tester.takeException(), isNull);
  });
}