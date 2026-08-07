import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Note popup: tapping a mark opens this editor to view / edit / delete the
/// note attached to it (FEATURES 4.4.2). Draggable (FEATURES 8.4), Esc
/// closes.
///
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when closed.
class NotePopup extends ConsumerStatefulWidget {
  const NotePopup({super.key});

  @override
  ConsumerState<NotePopup> createState() => _NotePopupState();
}

class _NotePopupState extends ConsumerState<NotePopup> {
  final _controller = TextEditingController();
  Offset? _dragPos;
  bool _synced = false; // controller initialized from the current annotation

  static const Size _size = Size(340, 300);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Load the annotation's content into the editor once per open.
  void _syncContent(TextAnnotation? ann) {
    if (_synced || ann == null) return;
    _synced = true;
    _controller.text = ann.content ?? '';
  }

  Future<void> _save(int id) async {
    final content = _controller.text.trim();
    final ok = await ref
        .read(annotationProvider.notifier)
        .updateContent(id, content.isEmpty ? null : content);
    if (!mounted) return;
    ref.read(selectionProvider.notifier).closeNote();
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存失败')));
    }
  }

  Future<void> _delete(int id) async {
    final ok = await ref.read(annotationProvider.notifier).delete(id);
    if (!mounted) return;
    ref.read(selectionProvider.notifier).closeNote();
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('删除失败')));
    }
  }

  IconData _kindIcon(TextAnnotationKind kind) {
    switch (kind) {
      case TextAnnotationKind.highlight:
        return Icons.border_color;
      case TextAnnotationKind.underline:
        return Icons.format_underlined;
      case TextAnnotationKind.strikethrough:
        return Icons.format_strikethrough;
      case TextAnnotationKind.note:
        return Icons.edit_note;
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = ref.watch(selectionProvider.select((s) => s.noteTargetId));
    if (id == null) return const SizedBox.shrink();

    final ann = ref.watch(annotationProvider
        .select((a) => a.valueOrNull?.where((x) => x.id == id).firstOrNull));
    if (ann == null) return const SizedBox.shrink(); // already deleted
    _syncContent(ann);

    final screen = MediaQuery.sizeOf(context);
    final pos = _dragPos ??
        Offset(screen.width / 2 - _size.width / 2,
            screen.height / 2 - _size.height / 2 - 40);
    final theme = Theme.of(context);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) =>
            setState(() => _dragPos = Offset(pos.dx + d.delta.dx, pos.dy + d.delta.dy)),
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.surfaceContainerHigh,
          child: SizedBox(
            width: _size.width,
            height: _size.height,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_kindIcon(ann.kind),
                          size: 18, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text('第 ${ann.page + 1} 页 · 笔记',
                          style: theme.textTheme.titleSmall),
                      const Spacer(),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭',
                        onPressed: () => ref
                            .read(selectionProvider.notifier)
                            .closeNote(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    ann.text ?? '(无选区文本)',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      autofocus: true,
                      maxLines: null,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '编辑笔记…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () => _delete(ann.id),
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('删除'),
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => _save(ann.id),
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
