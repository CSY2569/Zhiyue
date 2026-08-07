import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Note composer: opened by the toolbar's 笔记 button, edits a note attached
/// to the current selection (FEATURES 4.4.1). Enter saves, Esc cancels.
///
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when closed.
class NoteComposer extends ConsumerStatefulWidget {
  const NoteComposer({super.key});

  @override
  ConsumerState<NoteComposer> createState() => _NoteComposerState();
}

class _NoteComposerState extends ConsumerState<NoteComposer> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = ref.read(selectionProvider);
    final sel = state.selection;
    if (sel == null) return;
    final content = _controller.text.trim();
    final ok = await ref.read(annotationProvider.notifier).create(
          kind: TextAnnotationKind.note,
          page: sel.page,
          text: sel.text,
          content: content.isEmpty ? null : content,
          rects: sel.lineRects,
          color: colorToHex(Theme.of(context).colorScheme.primary),
        );
    if (!mounted) return;
    // Drop the selection and the composer either way (FEATURES 4.4.1).
    ref.read(selectionProvider.notifier).clear();
    if (!ok) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('保存笔记失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(selectionProvider);
    final pos = state.composerPos;
    final sel = state.selection;
    if (pos == null || sel == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Positioned(
      left: pos.dx,
      top: pos.dy,
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHigh,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340, maxHeight: 260),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('添加笔记', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  sel.text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  maxLines: null,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '输入笔记内容…',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => ref
                          .read(selectionProvider.notifier)
                          .closeComposer(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: _save, child: const Text('保存')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
