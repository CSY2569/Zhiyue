import 'package:flutter/material.dart';

import 'package:rbwa/core/widgets/text_input_dialog.dart';

/// Shows a modal dialog for creating or renaming a category (FEATURES 2.8).
///
/// Returns the entered name (trimmed), or `null` if the user cancelled.
/// Validation (non-empty, uniqueness) is handled by the caller.
Future<String?> showCategoryEditDialog(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  return showTextInputDialog(
    context,
    title: title,
    initial: initial,
    label: '分类名称',
  );
}
