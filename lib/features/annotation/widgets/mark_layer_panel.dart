import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';

/// Layer management panel (FEATURES 5.5): all image-layer marks of the open
/// book, grouped by page, with per-type visibility toggles, per-mark
/// deletion and a layer-wide clear. Mirrors the text-annotation sidebar.
class MarkLayerPanel extends ConsumerWidget {
  const MarkLayerPanel({super.key, this.onJump});

  /// Jump callback receiving a 0-indexed page.
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final marks = ref.watch(imageMarkProvider).valueOrNull ?? const [];
    final visibility = ref.watch(markVisibilityProvider);
    return SizedBox(
      width: 240,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            _FilterBar(visibility: visibility),
            const Divider(height: 8),
            Expanded(
              child: marks.isEmpty
                  ? const _EmptyHint()
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: _groupedItems(marks, visibility),
                    ),
            ),
            const _ClearBar(hasMarks: false),
          ],
        ),
      ),
    );
  }

  List<Widget> _groupedItems(List<ImageMark> marks, Set<ImageMarkKind> visible) {
    final items = <Widget>[];
    for (var i = 0; i < marks.length;) {
      if (!visible.contains(marks[i].kind)) {
        i++;
        continue;
      }
      final page = marks[i].page;
      items.add(_PageHeader(page: page));
      while (i < marks.length && marks[i].page == page) {
        items.add(_MarkTile(mark: marks[i], onJump: onJump));
        i++;
      }
    }
    return items;
  }
}

/// Per-type visibility chips (FEATURES 5.5: filter show / hide by type).
class _FilterBar extends ConsumerWidget {
  const _FilterBar({required this.visibility});

  final Set<ImageMarkKind> visibility;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final kind in ImageMarkKind.values)
            FilterChip(
              label: Text(
                switch (kind) {
                  ImageMarkKind.brush => '画笔',
                  ImageMarkKind.shape => '形状',
                  ImageMarkKind.sticky => '便签',
                  ImageMarkKind.stamp => '图章',
                },
                style: Theme.of(context).textTheme.labelSmall,
              ),
              selected: visibility.contains(kind),
              visualDensity: VisualDensity.compact,
              onSelected: (_) =>
                  ref.read(markVisibilityProvider.notifier).toggle(kind),
            ),
        ],
      ),
    );
  }
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(
        '第 ${page + 1} 页',
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

class _MarkTile extends ConsumerWidget {
  const _MarkTile({required this.mark, this.onJump});

  final ImageMark mark;
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = switch (mark.kind) {
      ImageMarkKind.brush => '画笔（${mark.brushPoints.length} 点）',
      ImageMarkKind.shape => '形状：${switch (mark.shapeType) {
        'ellipse' => '椭圆',
        'arrow' => '箭头',
        _ => '矩形',
      }}',
      ImageMarkKind.sticky => mark.stickyText ?? '便签',
      ImageMarkKind.stamp => mark.stampFile?.split('/').last ?? '图章',
    };
    return ListTile(
      dense: true,
      leading: Icon(
        switch (mark.kind) {
          ImageMarkKind.brush => Icons.brush_outlined,
          ImageMarkKind.shape => Icons.rectangle_outlined,
          ImageMarkKind.sticky => Icons.sticky_note_2_outlined,
          ImageMarkKind.stamp => Icons.image_outlined,
        },
        size: 18,
      ),
      title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        icon: const Icon(Icons.close, size: 16),
        tooltip: '删除标记',
        visualDensity: VisualDensity.compact,
        onPressed: () => ref.read(imageMarkProvider.notifier).delete(mark.id),
      ),
      onTap: onJump == null ? null : () => onJump!(mark.page),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          '暂无批注标记\n使用工具栏的画笔 / 形状 / 便签 / 图章',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _ClearBar extends ConsumerWidget {
  const _ClearBar({required this.hasMarks});

  final bool hasMarks;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: TextButton.icon(
        onPressed: hasMarks
            ? () => ref.read(imageMarkProvider.notifier).clearAll()
            : null,
        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
        label: const Text('清空全部标记'),
      ),
    );
  }
}
