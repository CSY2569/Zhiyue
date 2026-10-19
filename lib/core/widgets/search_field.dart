import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

/// Search field with a debounced [onChanged] callback (FEATURES 2.7 / 3.5.2).
///
/// The library title filter and the full-text search page used to carry
/// identical controller/timer/clear-button code; this widget owns that
/// lifecycle. [pill] selects the rounded filled style used in the library
/// toolbar; the default is the outlined style used on the search page.
class DebouncedSearchField extends StatefulWidget {
  const DebouncedSearchField({
    super.key,
    required this.hint,
    required this.onChanged,
    this.autofocus = false,
    this.pill = false,
    this.fillColor,
    this.duration = const Duration(milliseconds: 300),
  });

  final String hint;
  final ValueChanged<String> onChanged;
  final bool autofocus;
  final bool pill;
  final Color? fillColor;
  final Duration duration;

  @override
  State<DebouncedSearchField> createState() => _DebouncedSearchFieldState();
}

class _DebouncedSearchFieldState extends State<DebouncedSearchField> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _hasText = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _hasText = value.isNotEmpty);
    _debounce?.cancel();
    _debounce = Timer(widget.duration, () => widget.onChanged(value));
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() => _hasText = false);
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) {
    final border = widget.pill
        ? OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
            borderSide: BorderSide.none,
          )
        : const OutlineInputBorder();
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      onChanged: _onChanged,
      decoration: InputDecoration(
        hintText: widget.hint,
        prefixIcon: const Icon(LucideIcons.search, size: 20),
        isDense: true,
        contentPadding:
            widget.pill ? const EdgeInsets.symmetric(vertical: 0) : null,
        border: border,
        filled: widget.pill,
        fillColor: widget.pill ? widget.fillColor : null,
        suffixIcon: _hasText
            ? IconButton(
                icon: const Icon(LucideIcons.x, size: 20),
                tooltip: '清空',
                visualDensity: VisualDensity.compact,
                onPressed: _clear,
              )
            : null,
      ),
    );
  }
}
