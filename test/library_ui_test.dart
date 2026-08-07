import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/features/library/widgets/category_assign_dialog.dart';
import 'package:rbwa/features/library/widgets/library_toolbar.dart';
import 'package:rbwa/src/rust/models/book.dart';

void _noop() {}

Book _book({int? categoryId}) => Book(
      id: 1,
      title: '测试书',
      originalPath: '/x.pdf',
      storedPath: '/x.pdf',
      fileType: BookType.pdf,
      pageCount: 3,
      coverPath: null,
      favorite: false,
      categoryId: categoryId,
      lastOpenedAt: null,
      importedAt: 'now',
    );

/// Fixed category list for the assign dialog test.
class _FakeCategoriesNotifier extends CategoriesNotifier {
  @override
  Future<List<Category>> build() async => const [
        Category(id: 1, name: '小说', sortOrder: 0, createdAt: ''),
        Category(id: 2, name: '技术', sortOrder: 0, createdAt: ''),
      ];
}

void main() {
  testWidgets('toolbar no longer duplicates rail filters', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: const MaterialApp(
        home: Scaffold(
          appBar: LibraryToolbar(
            onToggleTheme: _noop,
            onOpenSettings: _noop,
          ),
        ),
      ),
    ));

    // Filter entry points live exclusively in the left rail.
    expect(find.text('PDF'), findsNothing);
    expect(find.text('图片'), findsNothing);
    expect(find.text('收藏'), findsNothing);
    // Search + actions remain.
    expect(find.text('搜索书名…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-clicking a book card offers "分配到分类…"',
      (tester) async {
    var assigned = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 180,
            height: 260,
            child: BookTile(
              book: _book(),
              onTap: _noop,
              onToggleFavorite: _noop,
              onAssignCategory: () => assigned = true,
              onDelete: _noop,
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(BookTile), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    expect(find.text('分配到分类…'), findsOneWidget);

    await tester.tap(find.text('分配到分类…'));
    await tester.pumpAndSettle();
    expect(assigned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('assign dialog lists 未分类 + categories and confirms choice',
      (tester) async {
    (int?, bool)? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        categoriesProvider.overrideWith(_FakeCategoriesNotifier.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showCategoryAssignDialog(
                    context,
                    _book(categoryId: 2), // currently in 技术
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('分配到分类'), findsOneWidget);
    expect(find.text('未分类'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    expect(find.text('技术'), findsOneWidget);

    // Choose 小说 and confirm.
    await tester.tap(find.text('小说'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, (1, true));
    expect(tester.takeException(), isNull);
  });

  testWidgets('assign dialog can unclassify', (tester) async {
    (int?, bool)? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        categoriesProvider.overrideWith(_FakeCategoriesNotifier.new),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result = await showCategoryAssignDialog(
                    context,
                    _book(categoryId: 1),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未分类'));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(result, (null, true));
    expect(tester.takeException(), isNull);
  });
}
