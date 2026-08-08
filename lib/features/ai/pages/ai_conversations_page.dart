import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart';

/// 「AI 对话」page (entry: the library toolbar button): every per-book
/// conversation window -- one window per book (6.5.4) -- in a two-pane
/// layout. The left pane lists the books; tapping one shows that book's
/// full conversation on the right. Deletion is centralized here (per book,
/// with confirmation): the reader side panel only chats and never removes
/// messages.
class AiConversationsPage extends ConsumerStatefulWidget {
  const AiConversationsPage({super.key});

  @override
  ConsumerState<AiConversationsPage> createState() =>
      _AiConversationsPageState();
}

class _AiConversationsPageState extends ConsumerState<AiConversationsPage> {
  int? _selectedId;

  @override
  Widget build(BuildContext context) {
    final threads = ref.watch(aiProvider).threads;
    // The selection survives window deletion (the right pane falls back to
    // the hint below); a stale id is harmless.
    final selected =
        threads.where((t) => t.id == _selectedId).firstOrNull;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left: books with conversations. Material (not a colored
        // DecoratedBox) so the ListTile ink/selection paints correctly.
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: Container(
            width: 280,
            decoration: BoxDecoration(
              border: Border(
                right: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            child: threads.isEmpty
                ? const _EmptyGuide()
                : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        '对话窗口',
                        style: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                    for (final t in threads)
                      ListTile(
                        dense: true,
                        selected: t.id == _selectedId,
                        leading: Icon(aiActionIcon(t.action), size: 18),
                        title: Text(
                          t.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${t.messages.length} 条消息',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          tooltip: '删除对话',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _confirmDelete(t),
                        ),
                        onTap: () => setState(() => _selectedId = t.id),
                      ),
                  ],
              ),
            ),
        ),
        // Right: the selected book's full conversation.
        Expanded(
          child: selected == null
              ? const _NoSelection()
              : SelectionArea(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    children: [
                      Text(
                        selected.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '共 ${selected.messages.length} 条消息',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color:
                                  Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Divider(height: 16),
                      for (final m in selected.messages)
                        AiMessageBubble(
                          role: m.role,
                          content: m.content,
                          imagePng: m.imagePng,
                          imagePath: m.imagePath,
                          maxWidth: 520,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// Per-book deletion (6.5.3) -- the only place conversations are removed.
  Future<void> _confirmDelete(AiThreadState window) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除对话'),
        content: Text(
          '确定删除「${window.title}」的对话？\n其中的所有消息将一并删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(aiProvider.notifier).deleteWindow(window.id);
    }
  }
}

/// Shown when no book has a conversation yet.
class _EmptyGuide extends StatelessWidget {
  const _EmptyGuide();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.forum_outlined, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text('暂无 AI 对话', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '在阅读时使用翻译 / 解释 / 搜索 / 识图，\n对话会按书保存在这里',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Right-pane hint before a book is selected.
class _NoSelection extends StatelessWidget {
  const _NoSelection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chevron_left, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 8),
          Text(
            '点击左侧书籍查看对话内容',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
