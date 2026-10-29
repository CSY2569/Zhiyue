import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/core/utils/clipboard.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/models/selection.dart'
    show Selection, SelectionSource;
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/src/rust/models/ai.dart';
import 'package:rbwa/src/rust/models/annotation.dart';
import 'package:rbwa/platform/platform_host.dart';

/// Toolbar shown for a completed selection (FEATURES 4.2): 8 actions
/// (翻译/解释/搜索/复制/高亮/下划线/删除线/笔记).
///
/// It always FLOATS next to the selection -- on phones too. The layout adapts
/// to the input device rather than to the window class:
///
///  * **Phones**: a compact 4×2 grid (icon above label, fixed cells), ~262dp
///    wide, because eight labelled buttons on one row need ~760dp. Floating
///    keeps the selected text visible, which is the whole point of a
///    selection toolbar.
///  * **Tablet / desktop**: one row of labelled buttons.
///
/// Placement uses the toolbar's REAL measured size: centred on the selection,
/// flipped above/below, clamped into the viewport (the clamp guards against an
/// inverted range when the bar is wider than the window). The bar is draggable
/// (FEATURES 4.2.2 / 8.4) -- the drag seeds the position from the bar's actual
/// origin, so the first move never jumps.
///
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when there is
/// no anchored selection (or while the note composer is open).
///
/// [bookId] / [bookTitle] snapshot the open book for the AI actions; null =
/// the no-book window.
class FloatingToolbar extends ConsumerStatefulWidget {
  const FloatingToolbar({super.key, this.bookId, this.bookTitle});

  final int? bookId;
  final String? bookTitle;

  @override
  ConsumerState<FloatingToolbar> createState() => _FloatingToolbarState();
}

class _FloatingToolbarState extends ConsumerState<FloatingToolbar> {
  /// Identifies the bar so a drag can start from its real screen position.
  final GlobalKey _surfaceKey = GlobalKey();

  /// Compact (phone) grid metrics: 4 columns × 2 rows.
  ///
  /// The cell is a MINIMUM, not a fixed box: 「下划线」and 「删除线」 are three
  /// CJK glyphs (~36dp at labelSmall) and their cell would overflow at 60dp.
  /// `IntrinsicWidth` around the bar lets the widest cell in each column
  /// decide the column width, so labels never clip.
  static const double _cellMinW = 62;
  static const double _cellH = 56;
  static const double _gridPad = 6;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(selectionProvider);
    final sel = state.selection;
    final anchor = state.toolbarAnchor;
    if (sel == null || anchor == null || state.composerPos != null) {
      return const SizedBox.shrink();
    }

    // "Compact" is about how much width the bar has, not just the platform:
    // a half-width tablet split still cannot fit eight labelled buttons.
    final width = MediaQuery.sizeOf(context).width;
    final compact = PlatformHost.current.compactUi(width);
    final actions = _actions(context, sel, vertical: compact);
    final theme = Theme.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = Size(constraints.maxWidth, constraints.maxHeight);
        return CustomSingleChildLayout(
          delegate: _ToolbarLayout(
            anchor: anchor,
            screen: screen,
            pos: state.toolbarPos,
          ),
          // `CustomSingleChildLayout` hands the child LOOSE constraints, so a
          // Row/Column here would size to infinity. IntrinsicWidth makes the
          // bar report its natural width; the delegate then positions it.
          child: IntrinsicWidth(
            child: GestureDetector(
              key: _surfaceKey,
              // Stable handle for layout tests: `FloatingToolbar` itself
              // fills the overlay, so size assertions need the bar's box.
              behavior: HitTestBehavior.translucent,
              onPanStart: (_) => _seedDragOrigin(),
              // Clamp to the viewport as the delegate does. Storing raw
              // accumulated coordinates made the bar stick at the edge while
              // the pointer kept moving (the "top edge no longer matches the
              // cursor" complaint); the stored position now always equals the
              // drawn one.
              onPanUpdate: (d) => _dragTo(screen, d.delta),
              child: compact
                  ? _compactSurface(theme, actions)
                  : _rowSurface(theme, actions),
            ),
          ),
        );
      },
    );
  }

  /// Writes the bar's current on-screen origin into [toolbarPos] before the
  /// first drag delta. Without this the first update would add a delta to a
  /// stale/null position and the bar would jump to a corner.
  void _seedDragOrigin() {
    final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    ref
        .read(selectionProvider.notifier)
        .moveToolbar(box.localToGlobal(Offset.zero));
  }

  /// Applies a drag step, clamped exactly like [_ToolbarLayout] so the stored
  /// position never drifts away from what is on screen.
  void _dragTo(Size screen, Offset delta) {
    final live = ref.read(selectionProvider).toolbarPos;
    if (live == null) return;
    final box = _surfaceKey.currentContext?.findRenderObject() as RenderBox?;
    final bar = box?.size ?? Size.zero;
    final maxLeft = screen.width - bar.width - 8;
    final maxTop = screen.height - bar.height - 8;
    final next = live + delta;
    ref.read(selectionProvider.notifier).moveToolbar(Offset(
          maxLeft < 8 ? 8.0 : next.dx.clamp(8.0, maxLeft),
          maxTop < 8 ? 8.0 : next.dy.clamp(8.0, maxTop),
        ));
  }

  /// Panel-styled container shared by both layouts (18dp radius, overlay
  /// fill, hairline border, soft shadow) so the bar matches the library's
  /// floating panels and the AI result card.
  Widget _panel(BuildContext context, Widget child) {
    // `Material` (not DecoratedBox) so the inner InkWells have an ink
    // surface; the visual language still comes from the panel decoration.
    return Material(
      key: const Key('selection-toolbar-surface'),
      color: appOverlayColor(context),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Golden.radiusPanel),
        side: BorderSide(color: appOverlayBorder(context)),
      ),
      child: child,
    );
  }

  /// Phone layout: a clean 4×2 grid of icon-over-label cells.
  Widget _compactSurface(ThemeData theme, List<Widget> actions) {
    Widget row(int start) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = start; i < start + 4 && i < actions.length; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: _cellMinW),
                child: SizedBox(height: _cellH, child: actions[i]),
              ),
          ],
        );
    return _panel(
      context,
      Padding(
        padding: const EdgeInsets.all(_gridPad),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [row(0), row(4)],
        ),
      ),
    );
  }

  /// Tablet / desktop layout: all eight labelled buttons on ONE row.
  ///
  /// This used to be a [Wrap]: `Wrap`'s max intrinsic width ignores its
  /// `spacing`, so `IntrinsicWidth` handed it a width 2dp short of the real
  /// row and the last button (笔记) wrapped onto a second line -- the "two-row
  /// toolbar" desktop regression. A [Row] measures exactly, and desktop
  /// windows are at least 960dp wide, where the ~560dp bar always fits.
  Widget _rowSurface(ThemeData theme, List<Widget> actions) {
    return _panel(
      context,
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: actions,
        ),
      ),
    );
  }

  /// The 8 selection actions in display order.
  List<Widget> _actions(
    BuildContext context,
    Selection sel, {
    required bool vertical,
  }) =>
      [
        _ToolButton(
          icon: LucideIcons.languages,
          label: '翻译',
          onTap: () => _aiAction(context, AiActionType.translate),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.lightbulb,
          label: '解释',
          onTap: () => _aiAction(context, AiActionType.explain),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.search,
          label: '搜索',
          onTap: () => _aiAction(context, AiActionType.search),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.copy,
          label: '复制',
          onTap: () => _copy(context, sel.text),
        ),
        _ToolButton(
          icon: LucideIcons.highlighter,
          label: '高亮',
          onTap: () => _mark(context, TextAnnotationKind.highlight),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.underline,
          label: '下划线',
          onTap: () => _mark(context, TextAnnotationKind.underline),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.strikethrough,
          label: '删除线',
          onTap: () => _mark(context, TextAnnotationKind.strikethrough),
          vertical: vertical,
        ),
        _ToolButton(
          icon: LucideIcons.filePlus2,
          label: '笔记',
          onTap: () => _openComposer(context),
          vertical: vertical,
        ),
      ];

  /// Start an AI action on the current selection (FEATURES 6.2), then drop
  /// the selection (the toolbar closes with it).
  Future<void> _aiAction(BuildContext context, AiActionType action) async {
    final sel = ref.read(selectionProvider).selection;
    if (sel == null) return;
    await ref
        .read(aiProvider.notifier)
        .startAction(action, sel.text, bookId: widget.bookId, bookTitle: widget.bookTitle);
    ref.read(selectionProvider.notifier).clear();
  }

  Future<void> _copy(BuildContext context, String text) async {
    await copyTextWithSnack(context, text, okLabel: '已复制选区文本');
  }

  /// Create a mark from the selection (FEATURES 4.3) and dismiss the toolbar.
  Future<void> _mark(BuildContext context, TextAnnotationKind kind) async {
    final sel = ref.read(selectionProvider).selection;
    if (sel == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(annotationProvider.notifier)
        .create(
          kind: kind,
          page: sel.page,
          text: sel.text,
          rects: sel.lineRects,
          color: colorToHex(Theme.of(context).colorScheme.primary),
          pane: sel.source == SelectionSource.translated
              ? AnnotationPane.translated
              : AnnotationPane.original,
        );
    ref.read(selectionProvider.notifier).clear();
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('创建标注失败')));
    }
  }

  /// Open the note composer (FEATURES 4.4.1).
  ///
  /// Touch: a marker position at the bottom edge -- the composer docks there
  /// and rises above the keyboard. Desktop: just below the floating toolbar.
  void _openComposer(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final mobile = PlatformHost.current.compactUi(screen.width);
    if (mobile) {
      ref
          .read(selectionProvider.notifier)
          .openComposer(Offset(0, screen.height));
      return;
    }
    final pos = ref.read(selectionProvider).toolbarPos;
    final base = pos ?? Offset(screen.width / 2 - 160, screen.height / 2 - 80);
    ref
        .read(selectionProvider.notifier)
        .openComposer(Offset(base.dx, base.dy + 56));
  }
}

/// Positions the floating toolbar with its MEASURED size: centred on the
/// selection, flipped above / below, and clamped into the viewport. The clamp
/// ranges are guarded so a toolbar wider than the screen pins to the left
/// margin instead of producing `lower > upper` (which throws).
class _ToolbarLayout extends SingleChildLayoutDelegate {
  _ToolbarLayout({required this.anchor, required this.screen, this.pos});

  final Rect anchor;
  final Size screen;

  /// User-dragged top-left position; null until the bar has been dragged.
  final Offset? pos;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      // The viewport's width/height, not the incoming loose constraints: a
      // Row/Column inside would otherwise be laid out with an infinite max
      // width (the classic "overflowed by N million pixels").
      BoxConstraints.loose(screen);

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // A user-dragged toolbar keeps the position the pan handler stored:
    // without this branch the drag updated `toolbarPos` but the layout kept
    // re-centring the bar on the selection, so dragging looked broken.
    if (pos != null) {
      final maxLeft = screen.width - childSize.width - 8;
      final maxTop = screen.height - childSize.height - 8;
      return Offset(
        maxLeft < 8 ? 8.0 : pos!.dx.clamp(8.0, maxLeft),
        maxTop < 8 ? 8.0 : pos!.dy.clamp(8.0, maxTop),
      );
    }

    final desiredLeft = anchor.left + anchor.width / 2 - childSize.width / 2;
    final maxLeft = screen.width - childSize.width - 8;
    final left =
        maxLeft < 8 ? 8.0 : desiredLeft.clamp(8.0, maxLeft);

    // Prefer above the selection; flip below when the top does not fit.
    var top = anchor.top - 8 - childSize.height;
    if (top < 8) top = anchor.bottom + 8;
    final maxTop = screen.height - childSize.height - 8;
    if (maxTop >= 8) top = top.clamp(8.0, maxTop);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_ToolbarLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.screen != screen ||
      oldDelegate.pos != pos;
}

/// Compact icon + label button for the toolbar.
///
/// [vertical] selects the phone grid form (icon above label, filling its
/// fixed cell) instead of the desktop row form (icon beside label). Both keep
/// the tap target at the full cell size.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.vertical = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = vertical
        ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          )
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 5),
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ],
          );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Golden.radiusSmall),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: vertical ? 5 : 9,
          vertical: vertical ? 4 : 7,
        ),
        child: content,
      ),
    );
  }
}
