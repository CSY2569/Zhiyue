import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/book_tile.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Responsive grid of book cards (FEATURES 2.2).
///
/// Watches [filteredBooksProvider] so it reactively updates on import, delete,
/// favorite, and filter changes. The empty-state guide is shown by the parent
/// page when there are no books at all; this widget only handles the non-empty
/// case (including the "no matches" sub-state).
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

    if (books.isEmpty) {
      return _NoMatches(theme: Theme.of(context));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 3 / 4.4,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return BookTile(
          book: book,
          onTap: () => onBookTap(book),
          onToggleFavorite: () => onToggleFavorite(book),
          onAssignCategory: () => onAssignCategory(book),
          onDelete: () => onDelete(book),
        );
      },
    );
  }
}

/// Shown when books exist but the current filter matches none.
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('没有匹配的书籍', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '尝试调整搜索词或筛选条件',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
