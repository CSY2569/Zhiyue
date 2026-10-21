import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/confirm_dialog.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/providers/library_selection_provider.dart';
import 'package:rbwa/features/library/widgets/category_pick_sheet.dart';

/// Bottom action bar shown while the library is in bulk-selection mode.
///
/// Touch-first: with several books selected, favorite / categorize / delete
/// in one place instead of opening the per-book context menu N times.
class LibrarySelectionBar extends ConsumerWidget {
  const LibrarySelectionBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(librarySelectionProvider);
    if (!selection.active) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final notifier = ref.read(librarySelectionProvider.notifier);
    final books = ref.read(libraryBooksProvider.notifier);

    return Material(
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              IconButton(
                tooltip: '取消多选',
                icon: const Icon(LucideIcons.x, size: 20),
                onPressed: notifier.clear,
              ),
              Expanded(
                child: Text(
                  '已选 ${selection.count} 本',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              _BarAction(
                icon: LucideIcons.star,
                label: '收藏',
                onTap: () async {
                  await books.setFavoriteMany(selection.ids, favorite: true);
                  if (context.mounted) notifier.clear();
                },
              ),
              _BarAction(
                icon: LucideIcons.tag,
                label: '分类',
                onTap: () async {
                  final categoryId = await showCategoryPickSheet(context);
                  if (categoryId == null || !context.mounted) return;
                  await books.assignCategoryMany(selection.ids, categoryId.$1);
                  if (context.mounted) notifier.clear();
                },
              ),
              _BarAction(
                icon: LucideIcons.trash2,
                label: '删除',
                danger: true,
                onTap: () async {
                  final ok = await showConfirmDialog(
                    context,
                    title: '删除 ${selection.count} 本书',
                    content: '阅读进度、标注、OCR 缓存将一并清除（AI 对话保留）。',
                  );
                  if (!ok || !context.mounted) return;
                  await books.deleteMany(selection.ids);
                  if (context.mounted) notifier.clear();
                },
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        danger ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        height: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
