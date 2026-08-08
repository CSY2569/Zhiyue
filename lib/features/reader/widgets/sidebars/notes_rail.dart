import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/annotation_icons.dart';
import 'package:rbwa/features/annotation/export_actions.dart';
import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Unified annotations sidebar (FEATURES 3.4.3 / 4.5.1 / 5.5): text-layer
/// marks and image-layer marks (brush / shape / sticky / stamp) listed
/// together, grouped by page, tap to jump, per-item delete, per-type
/// visibility filters for image marks, clear-all, and the export bar
/// (Markdown / JSON / merged image).
class NotesRail extends ConsumerWidget {
  const NotesRail({super.key, this.onJump});

  /// Jump callback receiving a 0-indexed page.
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anns = ref.watch(annotationProvider).valueOrNull ?? const [];
    final marks = ref.watch(imageMarkProvider).valueOrNull ?? const [];
    final visibility = ref.watch(markVisibilityProvider);
    final hasMarks = marks.isNotEmpty;
    final empty = anns.isEmpty && marks.isEmpty;

    return SizedBox(
      width: 240,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            if (hasMarks) _MarkFilterBar(visibility: visibility),
            Expanded(
              child: empty
                  ? const _EmptyHint()
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: _groupedItems(anns, marks, visibility),
                    ),
            ),
            if (hasMarks) const _ClearMarksBar(),
            const _ExportBar(),
          ],
        ),
      ),
    );
  }

  /// Flat widget list: one page header followed by that page's text
  /// annotations and visible image marks (both lists arrive sorted by page).
  List<Widget> _groupedItems(
    List<TextAnnotation> anns,
    List<ImageMark> marks,
    Set<ImageMarkKind> visible,
  ) {
    final pageItems = <int, List<Widget>>{};
    for (final ann in anns) {
      (pageItems[ann.page] ??= []).add(_AnnotationTile(ann: ann, onJump: onJump));
    }
    for (final m in marks) {
      if (!visible.contains(m.kind)) continue;
      (pageItems[m.page] ??= []).add(_MarkTile(mark: m, onJump: onJump));
    }
    final pages = pageItems.keys.toList()..sort();
    final items = <Widget>[];
    for (final page in pages) {
      items.add(_PageHeader(page: page));
      items.addAll(pageItems[page]!);
    }
    return items;
  }
}

/// Per-type visibility chips for image marks (FEATURES 5.5: filter show /
/// hide by type).
class _MarkFilterBar extends ConsumerWidget {
  const _MarkFilterBar({required this.visibility});

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

  final int page; // 0-indexed

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Text(
        '第 ${page + 1} 页',
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

/// One text annotation row: kind icon + selected text (+ note preview), tap
/// to jump to the page, swipe-to-delete (FEATURES 4.5.1).
class _AnnotationTile extends ConsumerWidget {
  const _AnnotationTile({required this.ann, this.onJump});

  final TextAnnotation ann;
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('ann-${ann.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: theme.colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: Icon(Icons.delete_outline,
            color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) =>
          ref.read(annotationProvider.notifier).delete(ann.id),
      child: InkWell(
        onTap: onJump == null ? null : () => onJump!(ann.page),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(textAnnotationIcon(ann.kind),
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ann.text ?? '(无选区文本)',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (ann.content != null && ann.content!.isNotEmpty)
                      Text(
                        ann.content!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18),
                visualDensity: VisualDensity.compact,
                tooltip: '删除标注',
                onPressed: () =>
                    ref.read(annotationProvider.notifier).delete(ann.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One image-layer mark row: kind icon + summary, tap to jump, delete
/// button (FEATURES 5.5).
class _MarkTile extends ConsumerWidget {
  const _MarkTile({required this.mark, this.onJump});

  final ImageMark mark;
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
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
    return InkWell(
      onTap: onJump == null ? null : () => onJump!(mark.page),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              switch (mark.kind) {
                ImageMarkKind.brush => Icons.brush_outlined,
                ImageMarkKind.shape => Icons.rectangle_outlined,
                ImageMarkKind.sticky => Icons.sticky_note_2_outlined,
                ImageMarkKind.stamp => Icons.image_outlined,
              },
              size: 16,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '删除标记',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  ref.read(imageMarkProvider.notifier).delete(mark.id),
            ),
          ],
        ),
      ),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.edit_note, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('暂无标注', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              '在页面中拖选文字添加标注，\n或使用工具栏的批注工具（画笔 / 形状 / 便签 / 图章）',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Clear-all for image-layer marks (FEATURES 5.5: 整体清空).
class _ClearMarksBar extends ConsumerWidget {
  const _ClearMarksBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: TextButton.icon(
        onPressed: () => ref.read(imageMarkProvider.notifier).clearAll(),
        icon: const Icon(Icons.delete_sweep_outlined, size: 16),
        label: const Text('清空全部标记'),
      ),
    );
  }
}

/// Bottom export bar: Markdown / JSON export buttons (FEATURES 4.5.2/4.5.3)
/// plus the merged-image export (5.6: page bitmap + marks -> PNG).
class _ExportBar extends ConsumerWidget {
  const _ExportBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      exportAnnotations(context, ref, format: 'markdown'),
                  icon: const Icon(Icons.description_outlined, size: 16),
                  label: const Text('Markdown'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () =>
                      exportAnnotations(context, ref, format: 'json'),
                  icon: const Icon(Icons.data_object, size: 16),
                  label: const Text('JSON'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => exportMergedImage(context, ref),
              icon: const Icon(Icons.image_outlined, size: 16),
              label: const Text('导出拼合图片（含批注）'),
            ),
          ),
        ],
      ),
    );
  }
}
