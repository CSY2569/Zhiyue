import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Show the "assign to category" dialog for [book].
///
/// Returns a record `(categoryId, confirmed)`:
/// - `null` when the user cancels;
/// - `(null, true)` when the user chooses "未分类" (unclassify);
/// - `(categoryId, true)` when a category was chosen.
Future<(int?, bool)?> showCategoryAssignDialog(
  BuildContext context,
  Book book,
) {
  return showDialog<(int?, bool)>(
    context: context,
    builder: (ctx) => _CategoryAssignDialog(book: book),
  );
}

/// Folder picker rendered with the same panel styling as the library.
///
/// The list reuses [AppSheetItem]'s pill language (not RadioListTile) so a
/// folder row looks identical here and in the rail.
class _CategoryAssignDialog extends ConsumerStatefulWidget {
  const _CategoryAssignDialog({required this.book});

  final Book book;

  @override
  ConsumerState<_CategoryAssignDialog> createState() =>
      _CategoryAssignDialogState();
}

class _CategoryAssignDialogState extends ConsumerState<_CategoryAssignDialog> {
  late int? _selected = widget.book.categoryId;

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider).valueOrNull ?? const <Category>[];
    final theme = Theme.of(context);

    return AppDialog(
      title: '移动到文件夹',
      subtitle: '「${widget.book.title}」',
      width: 420,
      body: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(
            children: [
              AppSheetItem(
                icon: LucideIcons.folderX,
                label: '未分类',
                selected: _selected == null,
                onTap: () => setState(() => _selected = null),
              ),
              for (final c in cats)
                AppSheetItem(
                  icon: LucideIcons.folder,
                  label: c.name,
                  selected: _selected == c.id,
                  onTap: () => setState(() => _selected = c.id),
                ),
              if (cats.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Golden.s13,
                    vertical: Golden.s21,
                  ),
                  child: Text(
                    '还没有文件夹。关闭这里后，在左侧「文件夹」页签新建。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        AppDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(context),
        ),
        AppDialogAction(
          label: '确定',
          primary: true,
          onPressed: () => Navigator.pop(context, (_selected, true)),
        ),
      ],
    );
  }
}
