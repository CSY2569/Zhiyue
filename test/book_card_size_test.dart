import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/book_grid.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

Book _book(int id, String title) => Book(
      id: id,
      title: title,
      originalPath: '/$id.pdf',
      storedPath: '/$id.pdf',
      fileType: BookType.pdf,
      pageCount: 100 + id,
      coverPath: null,
      favorite: false,
      categoryId: null,
      lastOpenedAt: null,
      importedAt: '2026-06-29 10:00:00',
    );

Widget _tile(Book book, double width, {double textScale = 1.0}) =>
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: Golden.cellHeightFor(width, textScale: textScale),
              child: BookTile(
                book: book,
                enableDrag: false,
                onTap: () {},
                onToggleFavorite: () {},
                onAssignCategory: () {},
                onDelete: () {},
              ),
            ),
          ),
        ),
      ),
    );

/// Two books: a short title (one line) and a long one (two lines).
final _shelf = [
  _book(11, 'Agent'),
  _book(12, '3D数学基础：图形和游戏开发（第2版）'),
];

class _Books extends LibraryBooksNotifier {
  @override
  Future<List<Book>> build() async => _shelf;
  @override
  Future<void> refresh() async => state = AsyncData(_shelf);
}

class _NoIndex extends SearchIndexStatusNotifier {
  @override
  Future<void> refresh() async {}
}

void main() {
  // The real grid must give every cell the same cover slot, whatever the
  // title length. This exercises the actual GridView geometry (the earlier
  // fixed-size test could not catch a mismatch between the grid's cell
  // extent and the card's text block).
  testWidgets('real grid: covers share one size across title lengths',
      (tester) async {
    tester.view.physicalSize = const Size(1136, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        libraryBooksProvider.overrideWith(_Books.new),
        libraryProgressProvider.overrideWith((ref) async => const {}),
        searchIndexStatusProvider.overrideWith(_NoIndex.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: BookGrid(
            onBookTap: (_) {},
            onToggleFavorite: (_) {},
            onAssignCategory: (_) {},
            onDelete: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final covers = tester
        .widgetList(find.byKey(const Key('book-cover')))
        .length;
    expect(covers, 2, reason: 'both cards should render');
    final rects = [
      for (var i = 0; i < covers; i++)
        tester.getRect(find.byKey(const Key('book-cover')).at(i)),
    ];
    expect(rects[0].size, rects[1].size);
    expect(rects[0].height, rects[0].width / Golden.coverRatio);
    // No overflow from the fixed text block.
    expect(tester.takeException(), isNull);
  });

  // Regression: covers used to be `Expanded`, so a one-line title left the
  // cover ~18dp taller than a two-line title in the same row.
  testWidgets('one-line and two-line titles yield identical cover sizes',
      (tester) async {
    const width = 184.0;

    await tester.pumpWidget(_tile(_book(1, 'Agent'), width));
    await tester.pumpAndSettle();
    final short = tester.getRect(find.byKey(const Key('book-cover')));

    await tester.pumpWidget(
      _tile(_book(2, '3D数学基础：图形和游戏开发（第2版）'), width),
    );
    await tester.pumpAndSettle();
    final long = tester.getRect(find.byKey(const Key('book-cover')));

    expect(short.size.width, closeTo(width, 0.5));
    expect(short.size.height, closeTo(long.size.height, 0.5));
    expect(short.size.width, closeTo(long.size.width, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cover keeps the sqrt-2 book proportion', (tester) async {
    const width = 184.0;
    await tester.pumpWidget(_tile(_book(3, '书'), width));
    await tester.pumpAndSettle();
    final cover = tester.getRect(find.byKey(const Key('book-cover')));
    expect(cover.width / cover.height, closeTo(Golden.coverRatio, 0.01));
  });

  testWidgets('accessibility font scaling does not squash the cover',
      (tester) async {
    const width = 184.0;
    // Render at 1.3x text scale; the cell grows by the same amount as the
    // text block, so the cover must keep its aspect ratio.
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          textScaler: TextScaler.linear(1.3),
          size: Size(800, 1200),
        ),
        child: _tile(_book(4, '长标题会换行到第二行'), width, textScale: 1.3),
      ),
    );
    await tester.pumpAndSettle();
    final cover = tester.getRect(find.byKey(const Key('book-cover')));
    expect(cover.width / cover.height, closeTo(Golden.coverRatio, 0.02));
    expect(tester.takeException(), isNull);
  });
}
