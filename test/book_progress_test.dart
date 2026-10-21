import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';

import 'package:rbwa/src/rust/models/book.dart';

Future<void> _pumpTile(
  WidgetTester tester, {
  required int pageCount,
  int? readPage,
  bool favorite = false,
}) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 184,
            height: Golden.cellHeightFor(184),
            child: BookTile(
              book: Book(
                id: 1,
                title: '测试书',
                originalPath: '/x.pdf',
                storedPath: '/x.pdf',
                fileType: BookType.pdf,
                pageCount: pageCount,
                coverPath: null,
                favorite: favorite,
                categoryId: null,
                lastOpenedAt: null,
                importedAt: 'now',
              ),
              readPage: readPage,
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
  ));
  await tester.pumpAndSettle();
}

void main() {
  group('shelf meta line', () {
    testWidgets('unread book shows date and total pages', (tester) async {
      await _pumpTile(tester, pageCount: 120);
      // No progress row -> the meta line is "date · N 页".
      expect(find.textContaining('120 页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('partially read book shows read over total', (tester) async {
      await _pumpTile(tester, pageCount: 300, readPage: 42);
      expect(find.textContaining('已读 42 / 300'), findsOneWidget);
    });

    testWidgets('finished book reads 已读完', (tester) async {
      await _pumpTile(tester, pageCount: 80, readPage: 80);
      expect(find.textContaining('已读完'), findsOneWidget);
    });

    testWidgets('progress beyond the page count clamps', (tester) async {
      // A shrunk PDF (re-import) can leave a stale higher page.
      await _pumpTile(tester, pageCount: 10, readPage: 99);
      expect(find.textContaining('已读完'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('favourite badge', () {
    testWidgets('sits on the cover, top-right, not in the meta line',
        (tester) async {
      await _pumpTile(tester, pageCount: 50, favorite: true);
      final heart = find.byIcon(LucideIcons.heart);
      expect(heart, findsOneWidget);

      final tile = tester.getRect(find.byType(BookTile));
      final heartRect = tester.getRect(heart);
      // Cover occupies the upper part of the card.
      expect(heartRect.center.dy, lessThan(tile.top + tile.height * 0.6));
      // ...and the badge is on the right half.
      expect(heartRect.center.dx, greaterThan(tile.center.dx));
    });

    testWidgets('unfavourited books still show the outline heart',
        (tester) async {
      await _pumpTile(tester, pageCount: 50);
      // The affordance stays discoverable; only the colour differs.
      expect(find.byIcon(LucideIcons.heart), findsOneWidget);
    });
  });
}
