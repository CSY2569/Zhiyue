import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';

/// Horizontal segmented filter bar above the shelf (reference design's
/// 「全部 / PDF / 笔记 / 文件夹」 pill row).
///
/// It complements the rail instead of duplicating it: the rail holds the
/// long-lived navigation (folders, AI, settings), while this bar is the quick
/// filter for the current list. The two stay in sync because both read
/// [libraryFilterProvider].
class LibraryFilterBar extends ConsumerWidget {
  const LibraryFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final notifier = ref.read(libraryFilterProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final items = <_FilterItem>[
      _FilterItem('全部', filter.view == LibraryView.all, notifier.showAll),
      _FilterItem('最近', filter.view == LibraryView.recent, notifier.showRecent),
      _FilterItem('PDF', filter.view == LibraryView.pdf, notifier.showPdf),
      _FilterItem('图片', filter.view == LibraryView.image, notifier.showImage),
      _FilterItem(
        '收藏',
        filter.view == LibraryView.favorite,
        notifier.showFavorites,
      ),
      if (filter.view == LibraryView.category && filter.categoryId != null)
        _FilterItem(
          '文件夹',
          true,
          () => notifier.setCategory(filter.categoryId),
        ),
    ];

    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: item.onTap,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color:
                        item.selected ? scheme.surface : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: item.selected
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight:
                          item.selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterItem {
  const _FilterItem(this.label, this.selected, this.onTap);

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

/// Row of the filter bar plus the result count, used by the shelf header.
class LibraryFilterHeader extends StatelessWidget {
  const LibraryFilterHeader({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Golden.s21,
        Golden.s13,
        Golden.s21,
        Golden.s8,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Expanded(child: LibraryFilterBar()),
          const SizedBox(width: Golden.s13),
          Text(
            '$count 本',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
