import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_composer_field.dart';
import 'package:rbwa/features/ai/widgets/ai_thread_tile.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart'
    show AiMessageBubble;
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// AI side panel (FEATURES 6.5): three-view state machine -- empty guide,
/// thread history list, or the active chat thread with streaming answers.
/// The bottom input bar supports Enter to send / Shift+Enter for a newline
/// (FEATURES 8.9).
///
/// [bookId] / [bookTitle] snapshot the open book for direct questions
/// (null = the no-book window).
class AiPanelSide extends ConsumerStatefulWidget {
  const AiPanelSide({
    super.key,
    this.bookId,
    this.bookTitle,
    this.fullScreen = false,
  });

  final int? bookId;
  final String? bookTitle;

  /// Phone layout: fill the available surface instead of the resizable
  /// desktop column width.
  final bool fullScreen;

  @override
  ConsumerState<AiPanelSide> createState() => _AiPanelSideState();
}

class _AiPanelSideState extends ConsumerState<AiPanelSide> {
  void _send(String text) {
    // Routes to the active thread, or starts a new chat thread (6.5.1).
    ref
        .read(aiProvider.notifier)
        .sendInput(text, bookId: widget.bookId, bookTitle: widget.bookTitle);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(aiProvider);
    final theme = Theme.of(context);
    final active = state.threadOf(state.activeThreadId);
    // Input is disabled while an answer is streaming (no concurrent sends).
    final inputEnabled = state.streamingThreadId == null;
    final width = ref.watch(panelLayoutProvider.select((p) => p.aiPanelWidth));

    final panel = Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.sparkles,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  // Shrinkable title: at narrow panel widths the action
                  // buttons take priority, so the title ellipsizes instead of
                  // overflowing the row (the panel is user-resizable).
                  Flexible(
                    child: Text(
                      'AI 助手',
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Spacer(),
                  // Inside a conversation: back to the window list. Deletion
                  // lives on the 「AI 对话」 page (6.5.3).
                  if (active != null)
                    IconButton(
                      icon: const Icon(LucideIcons.arrowLeft, size: 20),
                      tooltip: '对话列表',
                      visualDensity: VisualDensity.compact,
                      onPressed: () =>
                          ref.read(aiProvider.notifier).showWindowList(),
                    ),
                  if (state.threads.isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          ref.read(aiProvider.notifier).clearThreads(),
                      icon: const Icon(LucideIcons.broom, size: 16),
                      label: const Text('清空'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  IconButton(
                    icon: const Icon(LucideIcons.x, size: 20),
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
              child: AiComposerField(
                hint: '向 AI 提问…（Enter 发送）',
                enabled: inputEnabled,
                onSend: _send,
              ),
            ),
          ],
        ),
      );
    if (widget.fullScreen) return panel;
    return SizedBox(width: width, child: panel);
  }

  Widget _buildBody(AiState state, AiThreadState? active) {
    // After 「清空」 the panel stays on the empty guide until the next AI
    // action -- the window list must not reappear (6.5.3 view-only clear).
    if (state.panelCleared || state.threads.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.sparkles,
        title: 'AI 助手',
        message: '选择文字翻译 / 解释 / 搜索，\n或直接在下方向 AI 提问',
      );
    }
    if (active == null) {
      // A fresh conversation opens on the empty guide (history is never
      // auto-selected); the window list appears via 查看历史对话 / the back
      // button.
      if (!state.showingThreadList) {
        return EmptyState(
          icon: LucideIcons.sparkles,
          title: 'AI 助手',
          message: '选择文字翻译 / 解释 / 搜索，\n或直接在下方向 AI 提问',
          action: AiHistoryButton(
            onPressed: () => ref.read(aiProvider.notifier).showWindowList(),
          ),
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
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        const AiThreadListHeader(),
        for (final t in threads)
          AiThreadTile(
            thread: t,
            trailing: t.id == streamingThreadId
                ? const InlineSpinner(size: 16)
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
    //
    // LayoutBuilder derives the bubble width from the panel's actual width
    // (minus the list's horizontal padding) so the content reflows when the
    // panel is resized -- a fixed maxWidth would leave the bubbles narrow.
    return SelectionArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bubbleMax = (constraints.maxWidth - 20).clamp(
            120.0,
            double.infinity,
          );
          // reverse: the newest message sits at the bottom and the list opens
          // there, so a long history does not show its oldest turn first (the
          // result card uses the same idiom). Children are laid out
          // bottom-up, hence the reversed iteration.
          return ListView(
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            children: [
              if (streamingText != null)
                AiMessageBubble(
                  role: AiRole.assistant,
                  content: streamingText!,
                  streaming: true,
                  maxWidth: bubbleMax,
                ),
              for (final m in messages.reversed)
                AiMessageBubble(
                  role: m.role,
                  content: m.content,
                  imagePng: m.imagePng,
                  imagePath: m.imagePath,
                  actionType: m.actionType,
                  createdAt: m.createdAt,
                  maxWidth: bubbleMax,
                ),
            ],
          );
        },
      ),
    );
  }
}
