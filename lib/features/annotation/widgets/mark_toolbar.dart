import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/toolbar_icon_button.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart'
    show parseHexColor;

/// Inline annotation controls for the reader's chrome (FEATURES 5.1-5.5).
///
/// They used to live in a floating bar layered over the page (a second-level
/// toolbar that appeared after pressing 批注). They are now shown directly in
/// the reading chrome itself: the middle of the desktop toolbar, or a
/// scrollable row inside the phone's bottom bar.
///
/// Returns [SizedBox.shrink] when no tool is armed -- the caller keeps its
/// normal controls in that case.
class MarkToolOptions extends ConsumerWidget {
  const MarkToolOptions({
    super.key,
    this.showExit = true,
    this.compact = false,
  });

  /// Whether to render the trailing 「退出批注」 button. Callers that pin their
  /// own exit control (the phone bottom bar keeps it outside the scroll area
  /// so it is always reachable) pass `false`.
  final bool showExit;

  /// Tighter spacing for touch chrome: smaller slider and no divider margins,
  /// so more of the row fits before it has to scroll.
  final bool compact;

  static const List<String> _palette = [
    '#e53935', // red
    '#fb8c00', // orange
    '#fdd835', // yellow
    '#43a047', // green
    '#1e88e5', // blue
    '#8e24aa', // purple
    '#5d4037', // brown
    '#212121', // black
  ];


  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toolState = ref.watch(markToolProvider);
    final tool = toolState.tool;
    if (tool == null) return const SizedBox.shrink();

    final notifier = ref.read(markToolProvider.notifier);
    final markNotifier = ref.read(imageMarkProvider.notifier);
    final showStyle =
        tool == MarkTool.brush ||
        tool == MarkTool.shape ||
        tool == MarkTool.stamp;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ToolbarIconButton(
          icon: LucideIcons.navigation,
          tooltip: '选择/移动',
          active: tool == MarkTool.select,
          onTap: () => notifier.setTool(MarkTool.select),
        ),
        ToolbarIconButton(
          icon: LucideIcons.brush,
          tooltip: '画笔',
          active: tool == MarkTool.brush,
          onTap: () => notifier.setTool(MarkTool.brush),
        ),
        // Shape tool: a popup also picks the shape type (5.4).
        _ShapeTool(active: tool == MarkTool.shape),
        ToolbarIconButton(
          icon: LucideIcons.stickyNote,
          tooltip: '便签',
          active: tool == MarkTool.sticky,
          onTap: () => notifier.setTool(MarkTool.sticky),
        ),
        _StampTool(active: tool == MarkTool.stamp),
        if (!compact) const VDivider(),
        ToolbarIconButton(
          icon: LucideIcons.undo,
          tooltip: '撤销 (Ctrl+Z)',
          enabled: markNotifier.canUndo,
          onTap: markNotifier.canUndo ? () => markNotifier.undo() : null,
        ),
        ToolbarIconButton(
          icon: LucideIcons.redo,
          tooltip: '重做 (Ctrl+Shift+Z)',
          enabled: markNotifier.canRedo,
          onTap: markNotifier.canRedo ? () => markNotifier.redo() : null,
        ),
        if (showStyle) ...[
          if (!compact) const VDivider(),
          for (final c in _palette)
            _ColorDot(
              color: c,
              selected: toolState.color == c,
              onTap: () => notifier.setColor(c),
            ),
          SizedBox(
            width: compact ? 72 : 96,
            child: Slider(
              value: toolState.strokeWidth.clamp(1, 12),
              min: 1,
              max: 12,
              onChanged: notifier.setStrokeWidth,
            ),
          ),
          ToolbarIconButton(
            icon: LucideIcons.circle,
            tooltip: toolState.fill ? '实心填充开' : '空心（无填充）',
            active: toolState.fill,
            onTap: notifier.toggleFill,
          ),
        ],
        if (showExit) ...[
          if (!compact) const VDivider(),
          ToolbarIconButton(
            icon: LucideIcons.check,
            tooltip: '退出批注',
            onTap: () => notifier.setTool(null),
          ),
        ],
      ],
    );
  }
}

class _ShapeTool extends ConsumerWidget {
  const _ShapeTool({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final type = ref.watch(markToolProvider.select((s) => s.shapeType));
    return PopupMenuButton<String>(
      tooltip:
          '形状（${switch (type) {
            'ellipse' => '椭圆',
            'arrow' => '箭头',
            _ => '矩形',
          }}）',
      initialValue: type,
      onSelected: (t) {
        ref.read(markToolProvider.notifier).setShapeType(t);
        ref.read(markToolProvider.notifier).setTool(MarkTool.shape);
      },
      itemBuilder: (ctx) => const [
        PopupMenuItem(value: 'rect', child: Text('矩形')),
        PopupMenuItem(value: 'ellipse', child: Text('椭圆')),
        PopupMenuItem(value: 'arrow', child: Text('箭头')),
      ],
      child: IconButton(
        icon: Icon(switch (type) {
          'ellipse' => LucideIcons.circle,
          'arrow' => LucideIcons.arrowRight,
          _ => LucideIcons.squareDashed,
        }, size: 20),
        color: active ? Theme.of(context).colorScheme.primary : null,
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            ref.read(markToolProvider.notifier).setTool(MarkTool.shape),
      ),
    );
  }
}

class _StampTool extends ConsumerWidget {
  const _StampTool({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasFile = ref.watch(
      markToolProvider.select((s) => s.stampFile != null),
    );
    return IconButton(
      icon: const Icon(LucideIcons.image, size: 20),
      color: active ? theme.colorScheme.primary : null,
      tooltip: hasFile ? '图章（已选图片，点击页面放置）' : '图章（先选择图片）',
      visualDensity: VisualDensity.compact,
      onPressed: () async {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.image,
        );
        final path = result?.files.single.path;
        if (path == null || path.isEmpty) return;
        ref.read(markToolProvider.notifier).setStampFile(path);
        ref.read(markToolProvider.notifier).setTool(MarkTool.stamp);
      },
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: parseHexColor(color) ?? const Color(0xFFE53935),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? theme.colorScheme.primary : Colors.grey,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}
