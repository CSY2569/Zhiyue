import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_utils.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart'
    show AiMessageBubble;
import 'package:rbwa/src/rust/models/ai.dart' show AiRole;

/// Floating AI result card (FEATURES 6.4): shows the active thread's full
/// conversation -- every prior turn stays visible across follow-ups (6.5.2),
/// with the in-flight answer streaming as the bottom bubble. Draggable by its
/// title bar (8.4), Markdown rendering (GFM, 6.4.1), copy-whole-conversation,
/// expand-to-panel, close, and a stop button while streaming (6.3.2).
/// Rendered inside an OverlayPortal; returns [SizedBox.shrink] when hidden.
///
/// The card never closes by itself: it stays visible after streaming and
/// across follow-ups, and only the close button hides it.
///
/// [bookId] / [bookTitle] snapshot the open book for the follow-up input
/// (null = the no-book window).
class ResultCard extends ConsumerWidget {
  const ResultCard({super.key, this.bookId, this.bookTitle});

  final int? bookId;
  final String? bookTitle;

  static const double _cardWidth = 440;
  static const double _cardHeight = 360;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aiProvider);
    // Stays visible while streaming AND after completion (6.4.1); only user
    // actions (close / expand) hide it.
    if (!state.cardVisible) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final pos = state.cardPos;
    final thread = state.threadOf(state.activeThreadId);
    final messages = thread?.messages ?? const <AiChatMessage>[];
    // The bottom bubble streams while this thread's answer is in flight.
    final streamingHere = state.cardStreaming &&
        thread != null &&
        state.streamingThreadId == thread.id;
    final tail = streamingHere ? state.streamingText : null;
    final conversation =
        _conversationText(messages, streamingTail: tail);

    return Positioned(
      left: pos.dx.clamp(8.0, screen.width - _cardWidth - 8),
      top: pos.dy.clamp(8.0, screen.height - _cardHeight - 8),
      child: Material(
        elevation: 4,
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surfaceContainerHigh,
        child: SizedBox(
          width: _cardWidth,
          height: _cardHeight,
          child: Column(
            children: [
              // Title bar: the drag handle (FEATURES 8.4) -- kept off the
              // content area so the input field / messages stay gesture-clean.
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanUpdate: (d) =>
                    ref.read(aiProvider.notifier).moveCard(pos + d.delta),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text('AI 结果', style: theme.textTheme.titleSmall),
                      const Spacer(),
                      // Stop (while streaming) / copy / expand / close (6.4.1).
                      if (streamingHere)
                        _CardButton(
                          icon: Icons.stop_circle_outlined,
                          tooltip: '停止生成',
                          onTap: () =>
                              ref.read(aiProvider.notifier).cancelStreaming(),
                        ),
                      _CardButton(
                        icon: Icons.copy_outlined,
                        tooltip: '复制对话',
                        onTap: () => copyTextWithSnack(context, conversation,
                            okLabel: '已复制对话'),
                      ),
                      _CardButton(
                        icon: Icons.open_in_full_outlined,
                        tooltip: '展开到侧栏',
                        onTap: () =>
                            ref.read(aiProvider.notifier).moveCardToPanel(),
                      ),
                      _CardButton(
                        icon: Icons.close,
                        tooltip: '关闭',
                        onTap: () => ref.read(aiProvider.notifier).closeCard(),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 8),
              Expanded(
                // reverse: the newest message sits at the bottom and the
                // list stays pinned to it while content streams in.
                child: ListView(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                  children: [
                    if (tail != null)
                      tail.isEmpty
                          ? const _StreamingCursor()
                          : AiMessageBubble(
                              role: AiRole.assistant,
                              content: tail,
                              streaming: true,
                              maxWidth: 380,
                              aiColor: theme.colorScheme.surfaceContainerHighest,
                            ),
                    ...messages.reversed.map(
                      (m) => AiMessageBubble(
                        role: m.role,
                        content: m.content,
                        imagePng: m.imagePng,
                        imagePath: m.imagePath,
                        maxWidth: 380,
                        aiColor: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 8),
              _CardInput(
                streaming: streamingHere,
                bookId: bookId,
                bookTitle: bookTitle,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Whole conversation as plain text (copy button); role labels keep turns
  /// readable. Embedded screenshots are replaced with a placeholder.
  static String _conversationText(
    List<AiChatMessage> messages, {
    String? streamingTail,
  }) {
    final sb = StringBuffer();
    for (final m in messages) {
      sb.writeln('${m.role == AiRole.user ? '用户' : 'AI'}：${m.content}');
      sb.writeln();
    }
    if (streamingTail != null && streamingTail.isNotEmpty) {
      sb.writeln('AI：$streamingTail');
    }
    return sb.toString().trim();
  }
}

/// Conversation input on the card: multi-turn follow-up (FEATURES 6.5.2).
/// Enter sends / Shift+Enter adds a newline (8.9); disabled while streaming.
class _CardInput extends ConsumerStatefulWidget {
  const _CardInput({
    required this.streaming,
    this.bookId,
    this.bookTitle,
  });

  final bool streaming;
  final int? bookId;
  final String? bookTitle;

  @override
  ConsumerState<_CardInput> createState() => _CardInputState();
}

class _CardInputState extends ConsumerState<_CardInput> {
  final _input = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.streaming) return;
    final state = ref.read(aiProvider);
    final activeId = state.activeThreadId;
    _input.clear();
    if (activeId == null) {
      // No thread yet: asking directly creates a new chat thread (6.5.1).
      ref.read(aiProvider.notifier).askQuestion(
            text,
            bookId: widget.bookId,
            bookTitle: widget.bookTitle,
          );
    } else {
      ref.read(aiProvider.notifier).sendMessage(activeId, text);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isEnterWithoutShift(event)) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Focus(
        onKeyEvent: _onKey,
        child: TextField(
          controller: _input,
          focusNode: _focus,
          minLines: 1,
          maxLines: 3,
          enabled: !widget.streaming,
          decoration: InputDecoration(
            hintText: '输入追问…（Enter 发送）',
            isDense: true,
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: const Icon(Icons.send, size: 18),
              tooltip: '发送',
              visualDensity: VisualDensity.compact,
              onPressed: widget.streaming ? null : _send,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact icon button for the card header.
class _CardButton extends StatelessWidget {
  const _CardButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
    );
  }
}

/// Blinking "generating" indicator (FEATURES 6.3.1).
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(_controller),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text('生成中…', style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
