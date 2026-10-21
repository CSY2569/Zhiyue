import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/features/library/widgets/floating_panels.dart';
import 'package:rbwa/features/library/widgets/library_filter_bar.dart';
import 'package:rbwa/src/rust/models/book.dart';


void main() {
  group('floating panel shell', () {
    testWidgets('shows two rounded panels with a gutter between them',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: FloatingPanels(
            background: const Color(0xFFF4F2ED),
            sideWidth: 224,
            gap: 8,
            side: const PanelSurface(child: Text('SIDE')),
            content: const PanelSurface(child: Text('CONTENT')),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('SIDE'), findsOneWidget);
      expect(find.text('CONTENT'), findsOneWidget);
      // Two separate panels, not one sheet.
      expect(find.byType(PanelSurface), findsNWidgets(2));
      final side = tester.getRect(find.text('SIDE'));
      final content = tester.getRect(find.text('CONTENT'));
      expect(content.left, greaterThan(side.right));
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone mode hides the side panel', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: FloatingPanels(
            background: const Color(0xFFF4F2ED),
            phone: true,
            side: null,
            content: const PanelSurface(child: Text('CONTENT')),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('CONTENT'), findsOneWidget);
      expect(find.byType(PanelSurface), findsOneWidget);
    });
  });

  group('shelf card is borderless', () {
    testWidgets('no Card / border chrome around the cover', (tester) async {
      final book = Book(
        id: 1,
        title: '算法设计',
        originalPath: '/a.pdf',
        storedPath: '/a.pdf',
        fileType: BookType.pdf,
        pageCount: 575,
        coverPath: null,
        favorite: false,
        categoryId: null,
        lastOpenedAt: '2026-06-29 12:00:00',
        importedAt: 'now',
      );
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 184,
                height: Golden.cellHeightFor(184),
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
      ));
      await tester.pumpAndSettle();

      // The reference design has no card container: a Card here would add
      // Material elevation and padding the design does not have.
      expect(find.byType(Card), findsNothing);
      // Title is serif italic.
      final title = tester.widget<Text>(find.text('算法设计'));
      expect(title.style?.fontStyle, FontStyle.italic);
      expect(title.style?.fontFamily, 'serif');
      // Meta line carries the date and the page count.
      expect(find.textContaining('26/06/29'), findsOneWidget);
      expect(find.textContaining('575 页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('filter bar', () {
    testWidgets('renders one pill per view', (tester) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(12),
              child: LibraryFilterBar(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      for (final label in ['全部', '最近', 'PDF', '图片', '收藏']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(tester.takeException(), isNull);
    });
  });
}
