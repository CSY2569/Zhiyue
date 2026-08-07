import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/annotation_icons.dart';
import 'package:rbwa/features/annotation/export_actions.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Annotations sidebar (FEATURES 3.4.3 / 4.5.1): all annotations grouped by
/// page, tap to jump, swipe (or button) to delete, and export buttons
/// (Markdown / JSON) at the bottom.
class NotesRail extends ConsumerWidget {
  const NotesRail({super.key, this.onJump});

  /// Jump callback receiving a 0-indexed page.
  final void Function(int page)? onJump;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anns = ref.watch(annotationProvider).valueOrNull ?? const [];
    return SizedBox(
      width: 240,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Expanded(
              child: anns.isEmpty
                  ? const _EmptyHint()
                  : ListView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      children: _groupedItems(anns),
                    ),
            ),
            const _ExportBar(),
          ],
        ),
      ),
    );
  }

  /// Flat widget list: a page header followed by its annotation tiles
  /// (annotations are already sorted by page from the repo).
  List<Widget> _groupedItems(List<TextAnnotation> anns) {
    final items = <Widget>[];
    for (var i = 0; i < anns.length;) {
      final page = anns[i].page;
      items.add(_PageHeader(page: page));
      while (i < anns.length && anns[i].page == page) {
        items.add(_AnnotationTile(ann: anns[i], onJump: onJump));
        i++;
      }
    }
    return items;
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

/// One annotation row: kind icon + selected text (+ note preview), tap to
/// jump to the page, swipe-to-delete (FEATURES 4.5.1).
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
              '在页面中拖选文字，\n使用浮动工具条添加标注',
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
