import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

/// Whether [event] is Enter without Shift: sends the message. Shift+Enter
/// falls through to the field's default newline behavior (FEATURES 8.9).
bool _isEnterWithoutShift(KeyEvent event) =>
    event is KeyDownEvent &&
    event.logicalKey == LogicalKeyboardKey.enter &&
    !HardwareKeyboard.instance.isShiftPressed;

/// Chat input used by both AI surfaces (side panel and floating result card).
/// Enter sends, Shift+Enter inserts a newline (FEATURES 8.9); the card variant
/// additionally shows an explicit send button.
class AiComposerField extends StatefulWidget {
  const AiComposerField({
    super.key,
    required this.hint,
    required this.onSend,
    this.enabled = true,
    this.maxLines = 4,
    this.showSendButton = false,
  });

  final String hint;
  final void Function(String text) onSend;
  final bool enabled;
  final int maxLines;
  final bool showSendButton;

  @override
  State<AiComposerField> createState() => _AiComposerFieldState();
}

class _AiComposerFieldState extends State<AiComposerField> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || !widget.enabled) return;
    _input.clear();
    widget.onSend(text);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_isEnterWithoutShift(event)) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _onKey,
      child: TextField(
        controller: _input,
        minLines: 1,
        maxLines: widget.maxLines,
        enabled: widget.enabled,
        decoration: InputDecoration(
          hintText: widget.hint,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: widget.showSendButton
              ? IconButton(
                  icon: const Icon(LucideIcons.send, size: 20),
                  tooltip: '发送',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.enabled ? _send : null,
                )
              : null,
        ),
      ),
    );
  }
}
