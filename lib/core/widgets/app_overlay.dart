import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';

/// Shared shells for every modal surface (dialogs, bottom sheets, menus).
///
/// The library page is built from two rounded floating panels; Material's
/// stock `AlertDialog` / `showModalBottomSheet` / `PopupMenu` use different
/// radii, elevations and paddings, so they read as a different product
/// bolted on. Everything here reuses the panel tokens
/// ([Golden.radiusPanel], [Golden.panelShadow], the Fibonacci spacing ladder)
/// so a confirmation dialog looks like it belongs to the shelf.
///
/// Text treatment matches the library header: **serif** titles, plain
/// body text, and a `labelSmall`-sized hint line.

/// The surface colour of an overlay: the same panel fill used by the library.
Color appOverlayColor(BuildContext context) =>
    Theme.of(context).colorScheme.surfaceContainerLow;

/// The hairline that separates an overlay from what it covers.
Color appOverlayBorder(BuildContext context) =>
    Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6);

/// A modal dialog matching the floating-panel language.
///
/// Layout: serif title, optional subtitle, body, then a right-aligned action
/// row. Width is capped at 420dp and inset by [Golden.s34] so it never
/// touches the screen edge on a tablet.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    this.subtitle,
    this.body,
    required this.actions,
    this.width = 420,
    this.icon,
  });

  final String title;
  final String? subtitle;
  final Widget? body;
  final List<Widget> actions;
  final double width;

  /// Optional leading glyph shown before the title.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: Golden.s34,
        vertical: Golden.s34,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: appOverlayColor(context),
            borderRadius: BorderRadius.circular(Golden.radiusPanel),
            border: Border.all(color: appOverlayBorder(context)),
            boxShadow: Golden.panelShadow(theme.brightness),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Golden.s34,
              Golden.s21,
              Golden.s34,
              Golden.s21,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 20, color: scheme.primary),
                      const SizedBox(width: Golden.s13),
                    ],
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'serif',
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ],
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: Golden.s4),
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ],
                if (body != null) ...[
                  const SizedBox(height: Golden.s21),
                  body!,
                ],
                const SizedBox(height: Golden.s21),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: Golden.s8),
                      actions[i],
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Text action for [AppDialog] (and sheet footers), pill-shaped to match the
/// library's filter chips.
class AppDialogAction extends StatelessWidget {
  const AppDialogAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback onPressed;

  /// Filled with the primary colour (the confirming action).
  final bool primary;

  /// Tinted with the error colour (delete / destructive action).
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (primary) {
      return FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(
            horizontal: Golden.s21,
            vertical: Golden.s13,
          ),
        ),
        child: Text(label),
      );
    }
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: destructive ? scheme.error : scheme.onSurfaceVariant,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: Golden.s21,
          vertical: Golden.s13,
        ),
      ),
      child: Text(label),
    );
  }
}

/// A bottom sheet matching the floating-panel language.
///
/// Rounded top corners, a grab handle, a serif title row and an optional
/// trailing close button. Content is padded by [_pad] and scrolls when tall.
class AppSheet extends StatelessWidget {
  const AppSheet({
    super.key,
    this.title,
    this.subtitle,
    required this.children,
    this.showClose = false,
  });

  final String? title;
  final String? subtitle;
  final List<Widget> children;
  final bool showClose;

  static const double _pad = Golden.s21;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: appOverlayColor(context),
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(Golden.radiusPanel),
        ),
        border: Border.all(color: appOverlayBorder(context)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: Golden.s8),
            // Grab handle: signals "drag / dismiss" the way the reference
            // design's sheets do.
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.onSurfaceVariant.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  _pad,
                  Golden.s13,
                  Golden.s8,
                  0,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title!,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontFamily: 'serif',
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (subtitle != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                subtitle!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (showClose)
                      IconButton(
                        tooltip: '关闭',
                        icon: const Icon(LucideIcons.x, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                  ],
                ),
              ),
            SizedBox(height: title == null ? Golden.s8 : Golden.s4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(
                  Golden.s8,
                  0,
                  Golden.s8,
                  Golden.s13,
                ),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row inside [AppSheet]: icon + label + optional trailing text, with the
/// same pill highlight language as the rail items.
class AppSheetItem extends StatelessWidget {
  const AppSheetItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.danger = false,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? trailing;
  final bool danger;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = danger
        ? scheme.error
        : selected
            ? scheme.primary
            : null;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Golden.s13,
              vertical: Golden.s13,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: color ?? scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Golden.s13),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color ?? scheme.onSurface,
                    ),
                  ),
                ),
                if (trailing != null)
                  Text(
                    trailing!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [AppSheet] as a modal bottom sheet with the panel styling applied.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  required List<Widget> children,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    barrierColor: Colors.black.withValues(alpha: 0.42),
    builder: (ctx) => AppSheet(
      title: title,
      subtitle: subtitle,
      children: children,
    ),
  );
}
