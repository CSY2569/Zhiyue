import 'package:flutter/material.dart';

/// Shows a modal dialog for creating or renaming a category (FEATURES 2.8).
///
/// Returns the entered name (trimmed), or `null` if the user cancelled.
/// Validation (non-empty, uniqueness) is handled by the caller.
Future<String?> showCategoryEditDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  final formKey = GlobalKey<FormState>();

  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Form(
        key: formKey,
        child: TextFormField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '分类名称',
            border: OutlineInputBorder(),
          ),
          validator: (v) {
            if (v == null || v.trim().isEmpty) return '名称不能为空';
            return null;
          },
          onFieldSubmitted: (v) {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.pop(ctx, v.trim());
            }
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, null),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (formKey.currentState?.validate() ?? false) {
              Navigator.pop(ctx, controller.text.trim());
            }
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}
