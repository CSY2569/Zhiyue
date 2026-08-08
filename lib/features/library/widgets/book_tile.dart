import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// A single book card in the library grid (FEATURES 2.2 / 2.5 / 2.6).
///
/// Shows the cover (or a type placeholder icon), title, page count, and a
/// favorite star. The card is [Draggable] so it can be dropped onto a
/// category in the rail (FEATURES 2.8). Tap opens the reader; right-click or
/// long-press shows a context menu (open / favorite / assign category /
/// delete) -- the menu is the discoverable way to classify on desktop. AI
/// conversations are viewed and deleted on the 「AI 对话」 page instead.
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onAssignCategory,
    required this.onDelete,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onAssignCategory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Desktop right-click opens the same context menu as long-press
    // (Flutter has no built-in right-click menu on InkWell).
    return GestureDetector(
      onSecondaryTapDown: (_) => _showContextMenu(context),
      child: Dragger(
        book: book,
        child: _Card(
          book: book,
          theme: theme,
          onTap: onTap,
          onToggleFavorite: onToggleFavorite,
          onLongPress: () => _showContextMenu(context),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book_outlined),
              title: const Text('打开'),
              onTap: () {
                Navigator.pop(ctx);
                onTap();
              },
            ),
            ListTile(
              leading: Icon(book.favorite
                  ? Icons.star_rounded
                  : Icons.star_border_rounded),
              title: Text(book.favorite ? '取消收藏' : '收藏'),
              onTap: () {
                Navigator.pop(ctx);
                onToggleFavorite();
              },
            ),
            ListTile(
              leading: const Icon(Icons.label_outline),
              title: const Text('分配到分类…'),
              onTap: () {
                Navigator.pop(ctx);
                onAssignCategory();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: errorColor),
              title: Text('删除', style: TextStyle(color: errorColor)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Wraps the card in a [Draggable] carrying the [Book], for drop-to-classify.
/// Only the visual card is dragged; the feedback is a semi-transparent copy.
class Dragger extends StatelessWidget {
  const Dragger({super.key, required this.book, required this.child});

  final Book book;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<Book>(
      data: book,
      delay: const Duration(milliseconds: 200),
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 120,
          child: _Cover(book: book, theme: Theme.of(context), dimmed: true),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: child),
      child: child,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.book,
    required this.theme,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onLongPress,
  });

  final Book book;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _Cover(book: book, theme: theme)),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      book.favorite
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 20,
                      color: book.favorite
                          ? Colors.amber
                          : theme.colorScheme.outline,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    tooltip: book.favorite ? '取消收藏' : '收藏',
                    onPressed: onToggleFavorite,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cover image or type placeholder (FEATURES 2.6). Watches the search-index
/// status for the "索引中" badge (M6, 3.5.1).
class _Cover extends ConsumerWidget {
  const _Cover({required this.book, required this.theme, this.dimmed = false});

  final Book book;
  final ThemeData theme;
  final bool dimmed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Highlight the badge while the background full-text index build runs.
    final indexing =
        ref.watch(searchIndexStatusProvider.select((m) => m[book.id])) ==
            'building';
    Widget content;
    final cover = book.coverPath;
    // PDF covers are rendered at import (covers/{id}.png, FEATURES 2.6);
    // image books use the file itself as the cover.
    if (cover != null) {
      content = Image.file(
        File(cover),
        fit: BoxFit.cover,
        cacheWidth: 240, // downsample for memory (FEATURES perf note)
        errorBuilder: (_, _, _) => _placeholder(),
      );
    } else {
      content = _placeholder();
    }
    if (dimmed) {
      content = Opacity(opacity: 0.7, child: content);
    }
    // Page-count badge bottom-right; a "索引中" chip while the full-text
    // index build is in flight (M6, 3.5.1).
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          right: 4,
          bottom: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _pageLabel(),
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ),
        ),
        if (indexing) ...[
          Positioned(
            left: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xCCE65100),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '索引中',
                style: TextStyle(color: Colors.white, fontSize: 10),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _placeholder() {
    final icon = book.fileType == BookType.pdf
        ? Icons.picture_as_pdf_outlined
        : Icons.image_outlined;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(icon, size: 40, color: theme.colorScheme.outline),
    );
  }

  String _pageLabel() {
    if (book.fileType == BookType.pdf) {
      return book.pageCount > 0 ? '${book.pageCount} 页' : '-';
    }
    return '1 页';
  }
}
