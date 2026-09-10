import 'package:flutter/material.dart';

/// A thin vertical drag handle that resizes an adjacent panel (FEATURES 3.4.4
/// / 6.4): drag right to widen a left-hand sidebar, or drag left to widen a
/// right-hand panel (the caller negates the delta).
///
/// Purely presentational -- it reports the horizontal drag [onResize] (during
/// the gesture, cheap in-memory updates) and fires [onResizeEnd] once the drag
/// stops so the caller can persist the final size.
class PanelResizeHandle extends StatefulWidget {
  const PanelResizeHandle({
    super.key,
    required this.onResize,
    this.onResizeEnd,
    this.cursor = SystemMouseCursors.resizeLeftRight,
  });

  /// Horizontal drag delta in logical pixels (right positive).
  final void Function(double dx) onResize;

  /// Called when the drag gesture ends (persist the resulting size).
  final VoidCallback? onResizeEnd;

  /// Mouse cursor while hovering the handle.
  final MouseCursor cursor;

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) => widget.onResize(d.delta.dx),
        onHorizontalDragEnd: (_) => widget.onResizeEnd?.call(),
        child: Container(
          width: 6,
          color: _hover
              ? theme.colorScheme.primary.withValues(alpha: 0.35)
              : Colors.transparent,
          child: _hover
              ? Center(
                  child: Container(
                    width: 1,
                    color: theme.colorScheme.primary,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
