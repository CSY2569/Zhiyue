import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';

/// Shows a single-field modal dialog and returns the trimmed value, or null
/// when the user cancels / the field is empty.
///
/// Shared by category rename and language add so the controller lifecycle and
/// button layout live in one place. The dialog owns its controller (a
/// controller disposed right after `showDialog` returns trips "used after
/// disposed" during the exit animation).
Future<String?> showTextInputDialog(
  BuildContext context, {
  required String title,
  String initial = '',
  String? label,
  String? hint,
  String confirmLabel = '确定',
  String cancelLabel = '取消',
  TextInputType? keyboardType,
  int minLines = 1,
  int maxLines = 1,
  bool autofocus = true,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextInputDialog(
      title: title,
      initial: initial,
      label: label,
      hint: hint,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      keyboardType: keyboardType,
      minLines: minLines,
      maxLines: maxLines,
      autofocus: autofocus,
    ),
  );
}

class _TextInputDialog extends StatefulWidget {
  const _TextInputDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.hint,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.keyboardType,
    required this.minLines,
    required this.maxLines,
    required this.autofocus,
  });

  final String title;
  final String initial;
  final String? label;
  final String? hint;
  final String confirmLabel;
  final String cancelLabel;
  final TextInputType? keyboardType;
  final int minLines;
  final int maxLines;
  final bool autofocus;

  @override
  State<_TextInputDialog> createState() => _TextInputDialogState();
}

class _TextInputDialogState extends State<_TextInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppDialog(
      title: widget.title,
      width: 460,
      body: TextField(
        controller: _controller,
        autofocus: widget.autofocus,
        keyboardType: widget.keyboardType,
        minLines: widget.minLines,
        maxLines: widget.maxLines,
        style: Theme.of(context).textTheme.bodyMedium,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          isDense: true,
          filled: true,
          fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          // Pill-ish field matching the header search box (24dp radius).
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Golden.s13),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Golden.s13,
            vertical: Golden.s13,
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        AppDialogAction(
          label: widget.cancelLabel,
          onPressed: () => Navigator.pop(context),
        ),
        AppDialogAction(
          label: widget.confirmLabel,
          primary: true,
          onPressed: _submit,
        ),
      ],
    );
  }
}
