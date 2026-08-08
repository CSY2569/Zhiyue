import 'package:flutter/material.dart';

/// Centered icon + title + message placeholder shared by every empty state
/// in the app (library guide, AI guides, no-selection hints, no-match
/// filters). [titleStyle] / [messageStyle] override the defaults for the few
/// surfaces that use a larger or smaller type.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    this.iconSize = 40,
    this.title,
    this.titleStyle,
    this.message,
    this.messageStyle,
    this.extra,
    this.action,
  });

  final IconData icon;
  final double iconSize;
  final String? title;
  final TextStyle? titleStyle;
  final String? message;
  final TextStyle? messageStyle;

  /// A second, smaller line under [message] (e.g. supported formats).
  final String? extra;

  /// Optional bottom widget (e.g. a button into the next step).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: theme.colorScheme.outline),
            if (title != null) ...[
              const SizedBox(height: 12),
              Text(title!, style: titleStyle ?? theme.textTheme.titleMedium),
            ],
            if (message != null) ...[
              SizedBox(height: title == null ? 8 : 4),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: messageStyle ??
                    theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (extra != null) ...[
              const SizedBox(height: 4),
              Text(
                extra!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
