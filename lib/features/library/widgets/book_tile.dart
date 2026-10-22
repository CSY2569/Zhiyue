import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/platform/platform_host.dart';

/// A single book card in the library grid (FEATURES 2.2 / 2.5 / 2.6).
///
/// Shows the cover (or a type placeholder icon), title, page count, and a
/// favorite star. On desktop the card is [Draggable] so it can be dropped
/// onto a category in the rail (FEATURES 2.8); right-click or long-press
/// shows a context menu (open / favorite / assign category / delete).
///
/// On touch devices the drag wrapper is disabled: [LongPressDraggable] wins
/// the gesture arena at 200 ms and swallowed the 500 ms long-press, so the
/// context menu could never open. Mobile long-press now opens the menu, and
/// category assignment is still available from that menu.
class BookTile extends StatelessWidget {
  const BookTile({
    super.key,
    required this.book,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onAssignCategory,
    required this.onDelete,
    this.enableDrag,
    this.selecting = false,
    this.selected = false,
    this.onToggleSelected,
    this.onEnterSelection,
    this.readPage,
  });

  final Book book;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onAssignCategory;
  final VoidCallback onDelete;

  /// Overrides the platform default (drag on desktop, long-press menu on
  /// touch). Tests pass this to exercise both branches on one host.
  final bool? enableDrag;

  /// Bulk-selection mode: the card shows a check mark and tapping toggles the
  /// selection instead of opening the book.
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggleSelected;

  /// Enters bulk-selection mode from the context menu (multi-select lives on
  /// touch; desktop users already have the per-book menu).
  final VoidCallback? onEnterSelection;

  /// Last-read page (1-indexed) from the saved progress row. Null / 0 means
  /// the book has never been opened.
  final int? readPage;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final drag = enableDrag ?? !PlatformHost.current.touch;
    // Desktop right-click opens the same menu as long-press (Flutter has no
    // built-in right-click menu on InkWell). A mouse on Android hits this
    // too; a finger uses long-press.
    final card = _Card(
      book: book,
      theme: theme,
      onTap: selecting ? (onToggleSelected ?? onTap) : onTap,
      onToggleFavorite: onToggleFavorite,
      onPressStart: () => _showContextMenu(context),
      selecting: selecting,
      selected: selected,
      readPage: readPage,
    );
    return GestureDetector(
      onSecondaryTapDown: (_) => _showContextMenu(context),
      child: drag ? Dragger(book: book, child: card) : card,
    );
  }

  void _showContextMenu(BuildContext context) {
    showAppSheet<void>(
      context,
      title: book.title,
      subtitle: book.pageCount > 0 ? '${book.pageCount} 页' : null,
      children: [
        AppSheetItem(
          icon: LucideIcons.bookOpenText,
          label: '打开',
          onTap: () {
            Navigator.pop(context);
            onTap();
          },
        ),
        AppSheetItem(
          icon: book.favorite ? LucideIcons.heartOff : LucideIcons.heart,
          label: book.favorite ? '取消收藏' : '收藏',
          onTap: () {
            Navigator.pop(context);
            onToggleFavorite();
          },
        ),
        AppSheetItem(
          icon: LucideIcons.folderInput,
          label: '移动到文件夹…',
          onTap: () {
            Navigator.pop(context);
            onAssignCategory();
          },
        ),
        if (onEnterSelection != null && PlatformHost.current.touch)
          AppSheetItem(
            icon: LucideIcons.listChecks,
            label: '多选',
            trailing: '批量操作',
            onTap: () {
              Navigator.pop(context);
              onEnterSelection!();
            },
          ),
        AppSheetItem(
          icon: LucideIcons.trash2,
          label: '删除',
          danger: true,
          onTap: () {
            Navigator.pop(context);
            onDelete();
          },
        ),
      ],
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
    required this.onPressStart,
    this.selecting = false,
    this.selected = false,
    this.readPage,
  });

  final Book book;
  final ThemeData theme;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onPressStart;
  final bool selecting;
  final bool selected;
  final int? readPage;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Cover: no card chrome at all -- the artwork is the object. Only a
        // rounded clip and a whisper of shadow so it lifts off the panel.
        //
        // `AspectRatio` (not `Expanded`) is what guarantees one size across
        // the shelf: the cover's height is derived from its WIDTH and the √2
        // book proportion, so the title's line count cannot influence it.
        AspectRatio(
          aspectRatio: Golden.coverRatio,
          child: GestureDetector(
            key: const Key('book-cover'),
            onTap: onTap,
            onLongPress: onPressStart,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.16),
                          blurRadius: 8,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: _Cover(book: book, theme: theme),
                    ),
                  ),
                ),
                // Heart, top-right of the cover (reference design position).
                Positioned(
                  top: -2,
                  right: -2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: selecting ? null : onToggleFavorite,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            book.favorite
                                ? LucideIcons.heart
                                : LucideIcons.heart,
                            size: 20,
                            color: book.favorite
                                ? const Color(0xFFE05B6C)
                                : Colors.white,
                            shadows: book.favorite
                                ? null
                                : const [
                                    Shadow(
                                      color: Colors.black38,
                                      blurRadius: 3,
                                    ),
                                  ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (selecting)
                  Positioned(
                    top: Golden.s8,
                    left: Golden.s8,
                    child: Container(
                      decoration: BoxDecoration(
                        color: selected
                            ? theme.colorScheme.primary
                            : Colors.white.withValues(alpha: 0.9),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        selected ? LucideIcons.check : LucideIcons.circle,
                        size: 16,
                        color: selected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // Text block: whatever height the cover leaves in the cell. The cell
        // extent reserves exactly [Golden.textBlockHeight], so this is that
        // height in practice; the extra slack absorbs font metrics.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 9),
              // Title reserves exactly two lines whether or not it uses them,
              // so the meta line sits at the same baseline on every card
              // (a Spacer pushed it to the bottom on one-line titles and
              // right under the title on two-line ones).
              SizedBox(
                height: Golden.titleLineHeight(theme, _textScale(context)) * 2,
                child: GestureDetector(
                  onTap: onTap,
                  onLongPress: onPressStart,
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'serif',
                      fontStyle: FontStyle.italic,
                      height: 1.25,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                _metaLine(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  double _textScale(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(1.0);

  /// "YY/MM/DD · 575 页" for unread books, "已读 128 / 575 页" once opened
  /// (the date already says when). Imported date is the fallback.
  String _metaLine() {
    final total = book.pageCount;
    final read = readPage ?? 0;
    final date = _shortDate(book.lastOpenedAt ?? book.importedAt);
    final pages = total > 0 ? '$total 页' : '—';
    if (read <= 0) return date.isEmpty ? pages : '$date · $pages';
    if (total > 0 && read >= total) {
      return date.isEmpty ? '已读完' : '$date · 已读完';
    }
    return date.isEmpty ? '已读 $read / $total' : '$date · 已读 $read / $total';
  }

  /// `2026-06-29...` -> `26/06/29`; unparseable input is passed through.
  static final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})');

  static String _shortDate(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final m = _datePattern.firstMatch(raw);
    if (m == null) return '';
    return '${m.group(1)!.substring(2)}/${m.group(2)}/${m.group(3)}';
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
      // Fill the slot (`cover`, top-anchored): `contain` letterboxed images
      // whose aspect differed slightly from the slot, so a narrow cover
      // looked smaller than its neighbour even though the cells matched.
      // Anchoring at the top keeps titles/authors at the top of a book cover
      // (or the first line of a document page) from being cropped.
      content = Container(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Image.file(
          File(cover),
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          cacheWidth: 360, // ~2x the largest card width; downsample for memory
          errorBuilder: (_, _, _) => _placeholder(),
        ),
      );
    } else {
      content = _placeholder();
    }
    if (dimmed) {
      content = Opacity(opacity: 0.7, child: content);
    }
    // The page count moved to the meta strip (it reads better there and no
    // longer competes with the artwork). Only the transient index badge is
    // still an overlay.
    if (!indexing) return content;
    return Stack(
      fit: StackFit.expand,
      children: [
        content,
        Positioned(
          left: Golden.s8,
          bottom: Golden.s8,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Golden.s8,
              vertical: 2,
            ),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(Golden.radiusSmall),
            ),
            child: Text(
              '索引中',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _placeholder() {
    final icon = book.fileType == BookType.pdf
        ? LucideIcons.fileText
        : LucideIcons.image;
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(icon, size: 40, color: theme.colorScheme.outline),
      ),
    );
  }
}
