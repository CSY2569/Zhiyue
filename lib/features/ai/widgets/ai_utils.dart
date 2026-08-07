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

/// Whether [event] is Enter without Shift: sends the message. Shift+Enter
/// falls through to the field's default newline behavior (FEATURES 8.9).
bool isEnterWithoutShift(KeyEvent event) =>
    event is KeyDownEvent &&
    event.logicalKey == LogicalKeyboardKey.enter &&
    !HardwareKeyboard.instance.isShiftPressed;
