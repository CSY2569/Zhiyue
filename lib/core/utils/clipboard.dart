import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Copy [text] to the clipboard and surface the outcome in a SnackBar.
Future<void> copyTextWithSnack(
  BuildContext context,
  String text, {
  required String okLabel,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(SnackBar(content: Text(okLabel)));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('复制失败')));
  }
}
