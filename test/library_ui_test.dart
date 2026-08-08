import 'dart:convert' show base64Decode;
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/library/providers/library_providers.dart';
import 'helpers/widget_harness.dart';
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

/// 1x1 transparent PNG written to a temp file as a fake cover image.
String _writeFakeCover() {
  final p = '/tmp/rbwa_cover_test.png';
  File(p).writeAsBytesSync(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='));
  return p;
}

Widget _tile(Book book) => ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 260,
              child: BookTile(
                book: book,
                onTap: _noop,
                onToggleFavorite: _noop,
                onAssignCategory: _noop,
                onDelete: _noop,
              ),
            ),
          ),
        ),
      ),
    );

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
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
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
        categoriesProvider.overrideWith(FakeCategoriesNotifier.new),
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
        categoriesProvider.overrideWith(FakeCategoriesNotifier.new),
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

  testWidgets('pdf book with a generated cover renders the cover image',
      (tester) async {
    final cover = _writeFakeCover();
    addTearDown(() => File(cover).deleteSync());
    // PDF covers are generated at import (covers/{id}.png); the tile must
    // display them, not the type placeholder (FEATURES 2.6).
    // The FileImage decode runs inside runAsync: widget tests use a fake
    // async zone where real file I/O never completes on its own.
    await tester.runAsync(() async {
      await tester.pumpWidget(_tile(Book(
        id: 1,
        title: '带封面 PDF',
        originalPath: '/x.pdf',
        storedPath: '/x.pdf',
        fileType: BookType.pdf,
        pageCount: 10,
        coverPath: cover,
        favorite: false,
        categoryId: null,
        lastOpenedAt: null,
        importedAt: 'now',
      )));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('book without a cover falls back to the type placeholder',
      (tester) async {
    await tester.pumpWidget(_tile(_book()));

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.picture_as_pdf_outlined), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
