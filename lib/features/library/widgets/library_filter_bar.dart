import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';

/// File-type filter above the shelf (全部格式 / PDF / 图片).
///
/// The bar is a *type* axis only. The rail owns the library *views*
/// (所有文档 / 最近使用 / 我的收藏 / 文件夹), so the two no longer offer the
/// same five entries -- that duplication also made one tap light up an entry
/// in both places.
///
/// Exactly one item is selected at any time, drawn by a single sliding
/// indicator. The previous implementation gave every item its own animated
/// background; while the 160ms fade ran, the outgoing and incoming pills were
/// both visibly tinted, so a tap looked like it had selected two neighbouring
/// entries.
class LibraryFilterBar extends ConsumerWidget {
  const LibraryFilterBar({super.key});

  static const _items = [
    (label: '全部格式', type: LibraryType.all),
    (label: 'PDF', type: LibraryType.pdf),
    (label: '图片', type: LibraryType.image),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final notifier = ref.read(libraryFilterProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = _items.indexWhere((it) => it.type == filter.type);

    return Container(
      height: 44,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxWidth / _items.length;
          return Stack(
            children: [
              // One indicator slides between slots; nothing else is ever
              // tinted, so two entries can never look selected together.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                left: selected < 0 ? 0 : selected * slot,
                top: 0,
                bottom: 0,
                width: slot,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final item in _items)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => notifier.setType(item.type),
                        child: Center(
                          child: Text(
                            item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: item.type == filter.type
                                  ? scheme.onSurface
                                  : scheme.onSurfaceVariant,
                              fontWeight: item.type == filter.type
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
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
