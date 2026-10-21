import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/app_overlay.dart';

/// Destructive confirm dialog used across the app (delete book / category /
/// conversation, clear marks): title + content + 取消 / confirm actions.
/// Returns true when confirmed.
///
/// Rendered with [AppDialog] so it matches the library's floating panels
/// (18dp radius, panel fill, serif title) instead of Material's default
/// 28dp AlertDialog.
///
/// [confirmStyle] controls the confirm button: [ConfirmButtonStyle.destructive]
/// tints it with the error colour (the destructive convention),
/// [.filled] uses a primary filled pill, [.plain] a neutral text action.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '删除',
  ConfirmButtonStyle confirmStyle = ConfirmButtonStyle.destructive,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AppDialog(
      title: title,
      icon: confirmStyle == ConfirmButtonStyle.destructive
          ? LucideIcons.triangleAlert
          : LucideIcons.circleHelp,
      body: Text(
        content,
        style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(height: 1.55),
      ),
      actions: [
        AppDialogAction(
          label: '取消',
          onPressed: () => Navigator.pop(ctx, false),
        ),
        switch (confirmStyle) {
          ConfirmButtonStyle.destructive => AppDialogAction(
              label: confirmLabel,
              destructive: true,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ConfirmButtonStyle.filled => AppDialogAction(
              label: confirmLabel,
              primary: true,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ConfirmButtonStyle.plain => AppDialogAction(
              label: confirmLabel,
              onPressed: () => Navigator.pop(ctx, true),
            ),
        },
      ],
    ),
  );
  return ok == true;
}

/// Confirm-button styling for [showConfirmDialog].
enum ConfirmButtonStyle { destructive, filled, plain }
