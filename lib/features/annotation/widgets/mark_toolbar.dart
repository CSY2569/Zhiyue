import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';

/// Mark tools as a floating bar above the reading area (FEATURES 5.1-5.5):
/// rendered by the reader page while a mark tool is armed. The toolbar keeps
/// only the 批注 entry button, so the bar has room for the tool switcher,
/// undo / redo (5.7) and the style controls (color / thickness / fill).
class MarkToolBar extends ConsumerWidget {
  const MarkToolBar({super.key});

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
    final theme = Theme.of(context);
    final showStyle =
        tool == MarkTool.brush || tool == MarkTool.shape || tool == MarkTool.stamp;

    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Tool(
              icon: Icons.near_me_outlined,
              tooltip: '选择/移动',
              active: tool == MarkTool.select,
              onTap: () => notifier.setTool(MarkTool.select),
            ),
            _Tool(
              icon: Icons.brush_outlined,
              tooltip: '画笔',
              active: tool == MarkTool.brush,
              onTap: () => notifier.setTool(MarkTool.brush),
            ),
            // Shape tool: a popup also picks the shape type (5.4).
            _ShapeTool(active: tool == MarkTool.shape),
            _Tool(
              icon: Icons.sticky_note_2_outlined,
              tooltip: '便签',
              active: tool == MarkTool.sticky,
              onTap: () => notifier.setTool(MarkTool.sticky),
            ),
            _StampTool(active: tool == MarkTool.stamp),
            const _Divider(),
            _Tool(
              icon: Icons.undo,
              tooltip: '撤销 (Ctrl+Z)',
              enabled: markNotifier.canUndo,
              onTap: markNotifier.canUndo ? () => markNotifier.undo() : null,
            ),
            _Tool(
              icon: Icons.redo,
              tooltip: '重做 (Ctrl+Shift+Z)',
              enabled: markNotifier.canRedo,
              onTap: markNotifier.canRedo ? () => markNotifier.redo() : null,
            ),
            if (showStyle) ...[
              const _Divider(),
              for (final c in _palette)
                _ColorDot(
                  color: c,
                  selected: toolState.color == c,
                  onTap: () => notifier.setColor(c),
                ),
              SizedBox(
                width: 120,
                child: Slider(
                  value: toolState.strokeWidth.clamp(1, 12),
                  min: 1,
                  max: 12,
                  onChanged: notifier.setStrokeWidth,
                ),
              ),
              _Tool(
                icon: toolState.fill
                    ? Icons.circle
                    : Icons.circle_outlined,
                tooltip: toolState.fill ? '实心填充开' : '空心（无填充）',
                active: toolState.fill,
                onTap: notifier.toggleFill,
              ),
            ],
            const _Divider(),
            _Tool(
              icon: Icons.check,
              tooltip: '退出批注',
              onTap: () => notifier.setTool(null),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact icon button for the mark tool bar.
class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.tooltip,
    this.active = false,
    this.enabled = true,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: IconButton(
        icon: Icon(icon, size: 18),
        color: active
            ? theme.colorScheme.primary
            : (enabled ? null : theme.disabledColor),
        visualDensity: VisualDensity.compact,
        onPressed: enabled ? onTap : null,
      ),
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
      tooltip: '形状（${switch (type) {
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
        icon: Icon(
          switch (type) {
            'ellipse' => Icons.circle_outlined,
            'arrow' => Icons.arrow_right_alt,
            _ => Icons.rectangle_outlined,
          },
          size: 18,
        ),
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
    final hasFile =
        ref.watch(markToolProvider.select((s) => s.stampFile != null));
    return IconButton(
      icon: const Icon(Icons.image_outlined, size: 18),
      color: active ? theme.colorScheme.primary : null,
      tooltip: hasFile ? '图章（已选图片，点击页面放置）' : '图章（先选择图片）',
      visualDensity: VisualDensity.compact,
      onPressed: () async {
        final result =
            await FilePicker.platform.pickFiles(type: FileType.image);
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
          color: _parseHex(color),
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

Color _parseHex(String hex) {
  final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0xE53935;
  return Color(0xFF000000 | v);
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 20,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
