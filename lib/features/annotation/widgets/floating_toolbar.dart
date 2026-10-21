import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/utils/clipboard.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/models/selection.dart'
    show Selection, SelectionSource;
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/src/rust/models/ai.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Toolbar shown for a completed selection (FEATURES 4.2): 8 actions
/// (翻译/解释/搜索/复制/高亮/下划线/删除线/笔记).
///
/// Layout follows the input device:
///  - **Touch (phones)**: docked above the bottom safe area as a 4×2 grid.
///    Floating next to the selection does not work on a 360dp screen -- the
///    8 actions do not fit, and the old fixed-width estimate produced an
///    inverted clamp range (a runtime `ArgumentError`).
///  - **Mouse / tablet / desktop**: floats next to the selection, positioned
///    from the toolbar's REAL measured width and draggable (8.4).
///
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when there is
/// no anchored selection (or while the note composer is open).
///
/// [bookId] / [bookTitle] snapshot the open book for the AI actions; null =
/// the no-book window.
class FloatingToolbar extends ConsumerWidget {
  const FloatingToolbar({super.key, this.bookId, this.bookTitle});

  final int? bookId;
  final String? bookTitle;

  /// Preferred floating width (desktop estimate for the initial position
  /// before the first layout). Placement itself always uses the measured
  /// width, never this constant.
  static const double _estWidth = 760;
  static const double _estHeight = 48;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(selectionProvider);
    final sel = state.selection;
    final anchor = state.toolbarAnchor;
    if (sel == null || anchor == null || state.composerPos != null) {
      return const SizedBox.shrink();
    }

    final mobile = PlatformCapabilities.current().isMobile ||
        PlatformCapabilities.isCompactWidth(MediaQuery.sizeOf(context).width);
    final actions = _actions(context, ref, sel);

    if (mobile) return _dockedBar(context, actions);

    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final screen = Size(constraints.maxWidth, constraints.maxHeight);
        return CustomSingleChildLayout(
          delegate: _ToolbarLayout(anchor: anchor, screen: screen),
          child: _toolbarSurface(
            theme,
            actions,
            onPanUpdate: (d) => ref.read(selectionProvider.notifier).moveToolbar(
                  (state.toolbarPos ?? _centerOnAnchor(anchor, screen)) +
                      d.delta,
                ),
          ),
        );
      },
    );
  }

  /// Touch layout: full-width bar docked at the bottom of the reader.
  Widget _dockedBar(BuildContext context, List<Widget> actions) {
    final theme = Theme.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surfaceContainerHigh,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      Expanded(child: _cell(actions[i])),
                  ],
                ),
                Row(
                  children: [
                    for (var i = 4; i < actions.length; i++)
                      Expanded(child: _cell(actions[i])),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// One grid cell: at least 48dp tall so every action is a valid touch
  /// target, with the content centered.
  Widget _cell(Widget child) =>
      SizedBox(height: 48, child: Center(child: child));

  Widget _toolbarSurface(
    ThemeData theme,
    List<Widget> actions, {
    void Function(DragUpdateDetails)? onPanUpdate,
  }) {
    final material = Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Wrap(spacing: 2, runSpacing: 2, children: actions),
      ),
    );
    if (onPanUpdate == null) return material;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: onPanUpdate,
      child: material,
    );
  }

  /// The 8 selection actions in display order.
  List<Widget> _actions(BuildContext context, WidgetRef ref, Selection sel) => [
        _ToolButton(
          icon: LucideIcons.languages,
          label: '翻译',
          onTap: () => _aiAction(context, ref, AiActionType.translate),
        ),
        _ToolButton(
          icon: LucideIcons.lightbulb,
          label: '解释',
          onTap: () => _aiAction(context, ref, AiActionType.explain),
        ),
        _ToolButton(
          icon: LucideIcons.search,
          label: '搜索',
          onTap: () => _aiAction(context, ref, AiActionType.search),
        ),
        _ToolButton(
          icon: LucideIcons.copy,
          label: '复制',
          onTap: () => _copy(context, sel.text),
        ),
        _ToolButton(
          icon: LucideIcons.highlighter,
          label: '高亮',
          onTap: () => _mark(context, ref, TextAnnotationKind.highlight),
        ),
        _ToolButton(
          icon: LucideIcons.underline,
          label: '下划线',
          onTap: () => _mark(context, ref, TextAnnotationKind.underline),
        ),
        _ToolButton(
          icon: LucideIcons.strikethrough,
          label: '删除线',
          onTap: () => _mark(context, ref, TextAnnotationKind.strikethrough),
        ),
        _ToolButton(
          icon: LucideIcons.filePlus2,
          label: '笔记',
          onTap: () => _openComposer(context, ref),
        ),
      ];

  /// Horizontal centre for the floating toolbar before the user drags it.
  Offset _centerOnAnchor(Rect anchor, Size screen) => Offset(
        (anchor.left + anchor.width / 2 - _estWidth / 2).clamp(
          8.0,
          (screen.width - _estWidth - 8).clamp(8.0, double.infinity),
        ),
        anchor.top - 8 - _estHeight,
      );

  /// Start an AI action on the current selection (FEATURES 6.2), then drop
  /// the selection (the toolbar closes with it).
  Future<void> _aiAction(
    BuildContext context,
    WidgetRef ref,
    AiActionType action,
  ) async {
    final sel = ref.read(selectionProvider).selection;
    if (sel == null) return;
    await ref
        .read(aiProvider.notifier)
        .startAction(action, sel.text, bookId: bookId, bookTitle: bookTitle);
    ref.read(selectionProvider.notifier).clear();
  }

  Future<void> _copy(BuildContext context, String text) async {
    await copyTextWithSnack(context, text, okLabel: '已复制选区文本');
  }

  /// Create a mark from the selection (FEATURES 4.3) and dismiss the toolbar.
  Future<void> _mark(
    BuildContext context,
    WidgetRef ref,
    TextAnnotationKind kind,
  ) async {
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
  void _openComposer(BuildContext context, WidgetRef ref) {
    final screen = MediaQuery.sizeOf(context);
    final mobile = PlatformCapabilities.current().isMobile ||
        PlatformCapabilities.isCompactWidth(screen.width);
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
        .openComposer(Offset(base.dx, base.dy + _estHeight + 8));
  }
}

/// Positions the floating toolbar with its MEASURED size: centred on the
/// selection, flipped above / below, and clamped into the viewport. The clamp
/// ranges are guarded so a toolbar wider than the screen pins to the left
/// margin instead of producing `lower > upper` (which throws).
class _ToolbarLayout extends SingleChildLayoutDelegate {
  _ToolbarLayout({required this.anchor, required this.screen});

  final Rect anchor;
  final Size screen;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
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
      oldDelegate.anchor != anchor || oldDelegate.screen != screen;
}

/// Compact icon + label button for the toolbar. The docked (touch) layout
/// wraps it in a 48dp cell; the floating layout keeps the compact look.
class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
