import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/providers/library_selection_provider.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Responsive shelf of book cards (FEATURES 2.2).
///
/// Layout is solved from the available width rather than delegated to
/// `SliverGridDelegateWithMaxCrossAxisExtent`:
///
///  * the column count is derived from a target card width (~168dp), so a
///    wider window adds columns instead of inflating the covers;
///  * cards keep the golden-ratio cover ([Golden.coverRatio]), so every tile
///    is the same recognizable book shape at any column count;
///  * spacing uses the Fibonacci ladder (21dp between cards, 13/34dp page
///    padding), keeping gutters proportional to the cards.
///
/// The cell height is computed from the solved card width, so rows never
/// leave a sliver of empty space below the covers.
class BookGrid extends ConsumerWidget {
  const BookGrid({
    super.key,
    required this.onBookTap,
    required this.onToggleFavorite,
    required this.onAssignCategory,
    required this.onDelete,
  });

  final void Function(Book book) onBookTap;
  final void Function(Book book) onToggleFavorite;
  final void Function(Book book) onAssignCategory;
  final void Function(Book book) onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final books = ref.watch(filteredBooksProvider);
    final selection = ref.watch(librarySelectionProvider);
    final selectionNotifier = ref.read(librarySelectionProvider.notifier);
    // Last-read page per book (empty until the first progress probe lands --
    // the strip then reads "0 / M 页", which is also correct for new books).
    final progress = ref.watch(libraryProgressProvider).valueOrNull ?? const {};

    // Keep the selection consistent with the loaded books (a delete or filter
    // change can remove entries).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (books.isEmpty) return;
      selectionNotifier.retain({for (final b in books) b.id});
    });

    if (books.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.searchX,
        iconSize: 56,
        title: '没有匹配的书籍',
        message: '尝试调整搜索词或筛选条件',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Pad by the WINDOW width, not the content width: a 776dp tablet
        // leaves ~570dp after the rail, which must not be mistaken for a
        // phone and given phone-tight margins.
        // The floating panel already insets the shelf from the window edge,
        // so the grid only pads inside its own panel.
        const horizontalPadding = Golden.s21;
        final available = constraints.maxWidth - horizontalPadding * 2;
        final grid = Golden.gridFor(available);
        final cardWidth = grid.cardWidth;
        final textScale = MediaQuery.textScalerOf(context).scale(1.0);
        final cellHeight =
            Golden.cellHeightFor(cardWidth, textScale: textScale);

        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            Golden.s13,
            horizontalPadding,
            // Bottom breathing room so the last row clears the FAB / action
            // bar instead of hiding behind it.
            Golden.s89,
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: grid.columns,
            crossAxisSpacing: Golden.s34,
            mainAxisSpacing: Golden.s34,
            mainAxisExtent: cellHeight,
          ),
          itemCount: books.length,
          itemBuilder: (context, index) {
            final book = books[index];
            return BookTile(
              book: book,
              onTap: () {
                if (selection.active) {
                  selectionNotifier.toggle(book.id);
                } else {
                  onBookTap(book);
                }
              },
              onToggleFavorite: () => onToggleFavorite(book),
              onAssignCategory: () => onAssignCategory(book),
              onDelete: () => onDelete(book),
              selecting: selection.active,
              selected: selection.contains(book.id),
              onToggleSelected: () => selectionNotifier.toggle(book.id),
              onEnterSelection: selection.active
                  ? null
                  : () => selectionNotifier.begin(book.id),
              enableDrag: selection.active ? false : null,
              readPage: progress[book.id],
            );
          },
        );
      },
    );
  }
}
