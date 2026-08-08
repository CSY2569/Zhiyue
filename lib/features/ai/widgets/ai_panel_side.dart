import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_utils.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart'
    show AiMessageBubble, aiActionIcon;
import 'package:rbwa/src/rust/models/ai.dart';

/// AI side panel (FEATURES 6.5): three-view state machine -- empty guide,
/// thread history list, or the active chat thread with streaming answers.
/// The bottom input bar supports Enter to send / Shift+Enter for a newline
/// (FEATURES 8.9).
///
/// [bookId] / [bookTitle] snapshot the open book for direct questions
/// (null = the no-book window).
class AiPanelSide extends ConsumerStatefulWidget {
  const AiPanelSide({super.key, this.bookId, this.bookTitle});

  final int? bookId;
  final String? bookTitle;

  @override
  ConsumerState<AiPanelSide> createState() => _AiPanelSideState();
}

class _AiPanelSideState extends ConsumerState<AiPanelSide> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final state = ref.read(aiProvider);
    final active = state.threadOf(state.activeThreadId);
    _input.clear();
    setState(() => _sending = false);
    if (active == null) {
      // No thread yet: asking directly creates a new chat thread (6.5.1).
      ref.read(aiProvider.notifier).askQuestion(
            text,
            bookId: widget.bookId,
            bookTitle: widget.bookTitle,
          );
    } else {
      ref.read(aiProvider.notifier).sendMessage(active.id, text);
    }
  }

  /// Enter sends (when not shift); Shift+Enter falls through to the default
  /// newline behavior of the multiline field (FEATURES 8.9).
  KeyEventResult _onInputKey(FocusNode node, KeyEvent event) {
    if (isEnterWithoutShift(event)) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiProvider);
    final theme = Theme.of(context);
    final active = state.threadOf(state.activeThreadId);
    // Input is disabled while an answer is streaming (no concurrent sends).
    final inputEnabled = state.streamingThreadId == null;

    return SizedBox(
      width: 320,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Text('AI 助手', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  // Inside a conversation: back to the window list. Deletion
                  // lives on the 「AI 对话」 page (6.5.3).
                  if (active != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back, size: 18),
                      tooltip: '对话列表',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          ref.read(aiProvider.notifier).showWindowList(),
                    ),
                  if (state.threads.isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          ref.read(aiProvider.notifier).clearThreads(),
                      icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                      label: const Text('清空'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '关闭 AI 面板',
                    visualDensity: VisualDensity.compact,
                    onPressed: () =>
                        ref.read(aiProvider.notifier).togglePanel(),
                  ),
                ],
              ),
            ),
            const Divider(height: 8),
            // Body
            Expanded(child: _buildBody(state, active)),
            // Input bar
            Padding(
              padding: const EdgeInsets.all(8),
              child: Focus(
                onKeyEvent: _onInputKey,
                child: TextField(
                  controller: _input,
                  focusNode: _inputFocus,
                  minLines: 1,
                  maxLines: 4,
                  enabled: inputEnabled && !_sending,
                  decoration: InputDecoration(
                    hintText: '向 AI 提问…（Enter 发送）',
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AiState state, AiThreadState? active) {
    // After 「清空」 the panel stays on the empty guide until the next AI
    // action -- the window list must not reappear (6.5.3 view-only clear).
    if (state.panelCleared) {
      return const _EmptyGuide();
    }
    if (state.threads.isEmpty) {
      return const _EmptyGuide();
    }
    if (active == null) {
      // A fresh conversation opens on the empty guide (history is never
      // auto-selected); the window list appears via 查看历史对话 / the back
      // button.
      if (!state.showingThreadList) {
        return _EmptyGuide(
          onShowHistory: () =>
              ref.read(aiProvider.notifier).showWindowList(),
        );
      }
      return _ThreadList(
        threads: state.threads,
        streamingThreadId: state.streamingThreadId,
        onOpen: (id) => ref.read(aiProvider.notifier).openThread(id),
      );
    }
    return _ChatView(
      thread: active,
      streamingText: state.streamingThreadId == active.id
          ? state.streamingText
          : null,
    );
  }
}

class _EmptyGuide extends StatelessWidget {
  const _EmptyGuide({this.onShowHistory});

  /// When set (history exists and the panel is not in a 「清空」 state), the
  /// guide offers one tap into the 对话列表.
  final VoidCallback? onShowHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome_outlined,
                size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text('AI 助手', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '选择文字翻译 / 解释 / 搜索，\n或直接在下方向 AI 提问',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onShowHistory != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onShowHistory,
                icon: const Icon(Icons.history, size: 16),
                label: const Text('查看历史对话'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThreadList extends StatelessWidget {
  const _ThreadList({
    required this.threads,
    required this.streamingThreadId,
    required this.onOpen,
  });

  final List<AiThreadState> threads;
  final int? streamingThreadId;
  final void Function(int id) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            '对话窗口',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
        ),
        for (final t in threads)
          ListTile(
            dense: true,
            leading: Icon(aiActionIcon(t.action), size: 18),
            title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${t.messages.length} 条消息',
              style: theme.textTheme.bodySmall,
            ),
            trailing: t.id == streamingThreadId
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: () => onOpen(t.id),
          ),
      ],
    );
  }
}

class _ChatView extends StatelessWidget {
  const _ChatView({required this.thread, this.streamingText});

  final AiThreadState thread;
  final String? streamingText;

  @override
  Widget build(BuildContext context) {
    final messages = thread.messages;
    // SelectionArea makes every message text selectable with the mouse
    // (drag + Ctrl+C); right-click on a bubble copies that message.
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        children: [
          for (final m in messages)
            AiMessageBubble(
              role: m.role,
              content: m.content,
              imagePng: m.imagePng,
              imagePath: m.imagePath,
            ),
          if (streamingText != null)
            AiMessageBubble(
              role: AiRole.assistant,
              content: streamingText!,
              streaming: true,
            ),
        ],
      ),
    );
  }
}

