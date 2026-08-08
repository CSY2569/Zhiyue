import 'package:flutter/material.dart';

/// Compact tooltip + icon button used by the reader / annotation / AI card
/// toolbars (one shared look instead of four per-file copies).
class ToolbarIconButton extends StatelessWidget {
  const ToolbarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.active = false,
    this.enabled = true,
    this.iconSize = 18,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;

  /// Tinted with the primary color when the tool is armed.
  final bool active;

  final bool enabled;
  final double iconSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: iconSize),
        color: active
            ? theme.colorScheme.primary
            : (enabled ? null : theme.disabledColor),
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}

/// Thin vertical divider between toolbar groups.
class VDivider extends StatelessWidget {
  const VDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
