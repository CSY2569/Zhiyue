import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Radio list of "未分类" + all user categories; confirms via the actions.
/// Reads [categoriesProvider] directly, so it stays in sync with the rail.
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

    return AlertDialog(
      title: const Text('分配到分类'),
      content: SizedBox(
        width: 320,
        child: RadioGroup<int?>(
          groupValue: _selected,
          onChanged: (v) => setState(() => _selected = v),
          child: ListView(
            shrinkWrap: true,
            children: [
              const RadioListTile<int?>(
                title: Text('未分类'),
                value: null,
              ),
              for (final c in cats)
                RadioListTile<int?>(
                  title: Text(c.name),
                  value: c.id,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, (_selected, true)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
