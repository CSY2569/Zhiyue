import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/src/rust/models/ai.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Floating toolbar shown above a completed selection (FEATURES 4.2): 8
/// buttons (翻译/解释/搜索/复制/高亮/下划线/删除线/笔记), auto positioned
/// 8px above the selection (below when there is no room), and draggable by
/// the user (FEATURES 4.2.2 / 8.4).
///
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when there is
/// no anchored selection (or while the note composer is open).
class FloatingToolbar extends ConsumerWidget {
  const FloatingToolbar({super.key});

  // Estimated size used for auto positioning before layout. Buttons are
  // compact so 8 fit on one row at the minimum window width (960).
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

    final screen = MediaQuery.sizeOf(context);
    final autoPos = _autoPosition(anchor, screen);
    final pos = state.toolbarPos ?? autoPos;
    final theme = Theme.of(context);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) => ref
            .read(selectionProvider.notifier)
            .moveToolbar(pos + d.delta),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.surfaceContainerHigh,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Wrap(
              spacing: 2,
              runSpacing: 2,
              children: [
                _ToolButton(
                  icon: Icons.translate,
                  label: '翻译',
                  onTap: () =>
                      _aiAction(context, ref, AiActionType.translate),
                ),
                _ToolButton(
                  icon: Icons.lightbulb_outline,
                  label: '解释',
                  onTap: () =>
                      _aiAction(context, ref, AiActionType.explain),
                ),
                _ToolButton(
                  icon: Icons.search,
                  label: '搜索',
                  onTap: () => _aiAction(context, ref, AiActionType.search),
                ),
                _ToolButton(
                  icon: Icons.copy,
                  label: '复制',
                  onTap: () => _copy(context, ref, sel.text),
                ),
                _ToolButton(
                  icon: Icons.border_color,
                  label: '高亮',
                  onTap: () => _mark(context, ref, TextAnnotationKind.highlight),
                ),
                _ToolButton(
                  icon: Icons.format_underlined,
                  label: '下划线',
                  onTap: () =>
                      _mark(context, ref, TextAnnotationKind.underline),
                ),
                _ToolButton(
                  icon: Icons.format_strikethrough,
                  label: '删除线',
                  onTap: () =>
                      _mark(context, ref, TextAnnotationKind.strikethrough),
                ),
                _ToolButton(
                  icon: Icons.note_add_outlined,
                  label: '笔记',
                  onTap: () => _openComposer(context, ref),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Auto position: 8px above the selection, flipped below when the top
  /// overflows; horizontally centered on the selection, clamped to the screen.
  Offset _autoPosition(Rect anchor, Size screen) {
    var top = anchor.top - 8 - _estHeight;
    if (top < 0) top = anchor.bottom + 8;
    final left = (anchor.left + anchor.width / 2 - _estWidth / 2)
        .clamp(8.0, screen.width - _estWidth - 8);
    return Offset(left, top);
  }

  /// Start an AI action on the current selection (FEATURES 6.2), then drop
  /// the selection (the floating toolbar closes with it).
  Future<void> _aiAction(
    BuildContext context,
    WidgetRef ref,
    AiActionType action,
  ) async {
    final sel = ref.read(selectionProvider).selection;
    if (sel == null) return;
    await ref.read(aiProvider.notifier).startAction(action, sel.text);
    ref.read(selectionProvider.notifier).clear();
  }

  Future<void> _copy(BuildContext context, WidgetRef ref, String text) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    messenger.showSnackBar(const SnackBar(content: Text('已复制选区文本')));
  }

  /// Create a mark from the selection (FEATURES 4.3) and dismiss the toolbar.
  Future<void> _mark(
    BuildContext context,
    WidgetRef ref,
    TextAnnotationKind kind,
  ) async {
    final state = ref.read(selectionProvider);
    final sel = state.selection;
    if (sel == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(annotationProvider.notifier).create(
          kind: kind,
          page: sel.page,
          text: sel.text,
          rects: sel.lineRects,
          color: colorToHex(Theme.of(context).colorScheme.primary),
        );
    ref.read(selectionProvider.notifier).clear();
    if (!ok) {
      messenger.showSnackBar(const SnackBar(content: Text('创建标注失败')));
    }
  }

  /// Open the note composer below the toolbar (FEATURES 4.4.1).
  void _openComposer(BuildContext context, WidgetRef ref) {
    final pos = ref.read(selectionProvider).toolbarPos;
    final screen = MediaQuery.sizeOf(context);
    final base = pos ?? Offset(screen.width / 2 - 160, screen.height / 2 - 80);
    ref
        .read(selectionProvider.notifier)
        .openComposer(Offset(base.dx, base.dy + _estHeight + 8));
  }
}

/// Compact icon + label button for the toolbar.
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
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurface),
            ),
          ],
        ),
      ),
    );
  }
}
