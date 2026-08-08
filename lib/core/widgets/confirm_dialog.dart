import 'package:flutter/material.dart';

/// Destructive confirm dialog used across the app (delete book / category /
/// conversation, clear marks): title + content + 取消 / confirm actions.
/// Returns true when confirmed.
///
/// [confirmStyle] controls the confirm button: [ConfirmButtonStyle.destructive]
/// tints it with the error color (the destructive convention), [.filled] uses
/// a primary [FilledButton], [.plain] a neutral [TextButton].
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '删除',
  ConfirmButtonStyle confirmStyle = ConfirmButtonStyle.destructive,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        switch (confirmStyle) {
          ConfirmButtonStyle.destructive => TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              child: Text(confirmLabel),
            ),
          ConfirmButtonStyle.filled => FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
          ConfirmButtonStyle.plain => TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel),
            ),
        },
      ],
    ),
  );
  return ok == true;
}

/// Confirm-button styling for [showConfirmDialog].
enum ConfirmButtonStyle { destructive, filled, plain }
