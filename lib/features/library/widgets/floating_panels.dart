import 'package:flutter/material.dart';

/// The app's floating-panel shell.
///
/// The reference design is not an edge-to-edge window: two rounded panels
/// (navigation / content) float over the page background with a narrow gutter
/// between them, so the window reads as layered paper rather than one flat
/// sheet. This widget only draws that structure -- the panels themselves are
/// supplied by the caller.
///
/// On phones there is no room for two panels: the navigation becomes a drawer
/// and the content panel fills the screen (still inset by [phoneGap]).
class FloatingPanels extends StatelessWidget {
  const FloatingPanels({
    super.key,
    required this.background,
    this.side,
    required this.content,
    this.sideWidth = 224,
    this.gap = 8,
    this.radius = 18,
    this.phone = false,
  });

  /// Page colour behind the panels.
  final Color background;

  /// Side panel; null on phones or when collapsed.
  final Widget? side;
  final double sideWidth;
  final Widget content;

  /// Gutter between / around the panels.
  final double gap;

  /// Panel corner radius.
  final double radius;

  final bool phone;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: background,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(phone ? 0 : gap),
          child: side == null
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(phone ? 0 : radius),
                  child: content,
                )
              : Row(
                  children: [
                    SizedBox(
                      width: sideWidth,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: side,
                      ),
                    ),
                    SizedBox(width: gap),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(radius),
                        child: content,
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Rounded panel surface used by both the side and content panels.
class PanelSurface extends StatelessWidget {
  const PanelSurface({
    super.key,
    required this.child,
    this.color,
    this.radius = 18,
    this.border = true,
  });

  final Widget child;
  final Color? color;
  final double radius;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(radius),
        border: border
            ? Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5))
            : null,
      ),
      child: child,
    );
  }
}
