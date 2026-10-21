import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Touch-friendly folder picker, used by bulk selection.
///
/// Returns `(categoryId, true)` on choice -- `(null, true)` means "未分类",
/// null means cancelled -- mirroring [showCategoryAssignDialog] so callers
/// can share the result handling.
Future<(int?, bool)?> showCategoryPickSheet(BuildContext context) {
  return showModalBottomSheet<(int?, bool)>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    builder: (ctx) => const _CategoryPickSheet(),
  );
}

class _CategoryPickSheet extends ConsumerWidget {
  const _CategoryPickSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];

    return AppSheet(
      title: '移动到文件夹',
      subtitle: '选择后立即应用',
      showClose: true,
      children: [
        AppSheetItem(
          icon: LucideIcons.folderX,
          label: '未分类',
          onTap: () => Navigator.pop(context, (null, true)),
        ),
        for (final c in cats)
          AppSheetItem(
            icon: LucideIcons.folder,
            label: c.name,
            onTap: () => Navigator.pop(context, (c.id, true)),
          ),
        if (cats.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 13,
              vertical: 21,
            ),
            child: Text(
              '还没有文件夹。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
