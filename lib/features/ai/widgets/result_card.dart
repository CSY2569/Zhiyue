import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/core/utils/clipboard.dart';
import 'package:rbwa/core/widgets/toolbar_icon_button.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_composer_field.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart'
    show AiMessageBubble, aiActionLabel;
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/src/rust/models/ai.dart' show AiRole;
import 'package:rbwa/platform/platform_host.dart';

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

  /// The position `AiState` starts from before the user drags the card. On a
  /// phone that coordinate would put a clamped card in the top-left corner,
  /// so the card is centred while it still holds this value.
  static const Offset _defaultCardPos = Offset(80, 120);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(aiProvider);
    // Stays visible while streaming AND after completion (6.4.1); only user
    // actions (close / expand) hide it.
    if (!state.cardVisible) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final screen = MediaQuery.sizeOf(context);
    final persisted = ref.watch(panelLayoutProvider.select((p) => p.cardSize));
    final pos = state.cardPos;
    final thread = state.threadOf(state.activeThreadId);
    final messages = thread?.messages ?? const <AiChatMessage>[];
    // The bottom bubble streams while this thread's answer is in flight.
    final streamingHere =
        state.cardStreaming &&
        thread != null &&
        state.streamingThreadId == thread.id;
    final tail = streamingHere ? state.streamingText : null;
    final conversation = _conversationText(messages, streamingTail: tail);

    // Phones keep the FLOATING card (the user asked for it explicitly): the
    // persisted desktop size is clamped to the viewport instead of the card
    // being docked as a sheet. Reading apps put the answer next to the text
    // precisely so the page stays visible underneath.
    final compact =
        PlatformHost.current.compactUi(screen.width);
    final cardSize = _effectiveSize(persisted, screen, compact);
    // Bubbles reflow with the card width (was a hardcoded 380).
    final bubbleMax = (cardSize.width - 24).clamp(160.0, 1000.0);
    // Keep the card on screen; the lower bound guards against a card wider
    // than the window (clamp would otherwise get lower > upper).
    final maxLeft = (screen.width - cardSize.width - 12).clamp(
      12.0,
      double.infinity,
    );
    // Phones: reserve room for the on-screen keyboard so the input row is not
    // buried under it. `viewInsets` is zero while the keyboard is closed.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final maxTop = (screen.height - cardSize.height - 12 - keyboard).clamp(
      12.0,
      double.infinity,
    );
    // The persisted position is a desktop coordinate; on a phone it can point
    // outside the viewport, so the first frame is centred instead of clamped
    // into a corner.
    final centred = Offset(
      ((screen.width - cardSize.width) / 2).clamp(12.0, maxLeft),
      ((screen.height - cardSize.height) / 2 - keyboard / 2)
          .clamp(12.0, maxTop),
    );
    final placed = (compact && state.cardPos == _defaultCardPos) ? centred : pos;

    return Positioned(
      left: placed.dx.clamp(12.0, maxLeft),
      top: placed.dy.clamp(12.0, maxTop),
      child: Material(
        elevation: 0,
        color: Colors.transparent,
        child: SizedBox(
          width: cardSize.width,
          height: cardSize.height,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: appOverlayColor(context),
              borderRadius: BorderRadius.circular(Golden.radiusPanel),
              border: Border.all(color: appOverlayBorder(context)),
              boxShadow: Golden.panelShadow(theme.brightness),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Golden.radiusPanel),
              child: _cardBody(
                context,
                ref,
                theme,
                bubbleMax,
                streamingHere,
                tail,
                messages,
                conversation,
                compact: compact,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Writes the card's current top-left into the shared position before the
  /// first drag delta.
  ///
  /// Phones render the card centred while `cardPos` still holds the desktop
  /// default (80,120); without seeding, the first drag update would move from
  /// that default and the card would jump.
  void _beginDrag(BuildContext context, WidgetRef ref) {
    final screen = MediaQuery.sizeOf(context);
    final persisted = ref.read(panelLayoutProvider).cardSize;
    final compact = PlatformHost.current.compactUi(screen.width);
    final cardSize = _effectiveSize(persisted, screen, compact);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final maxLeft = (screen.width - cardSize.width - 12).clamp(12.0, double.infinity);
    final maxTop =
        (screen.height - cardSize.height - 12 - keyboard).clamp(12.0, double.infinity);
    final centred = Offset(
      ((screen.width - cardSize.width) / 2).clamp(12.0, maxLeft),
      ((screen.height - cardSize.height) / 2 - keyboard / 2)
          .clamp(12.0, maxTop),
    );
    final current = Offset(
      centred.dx.clamp(12.0, maxLeft),
      centred.dy.clamp(12.0, maxTop),
    );
    // Seed unconditionally: a new AI action resets `cardPos` to the desktop
    // default, and this drag is about to move the card from where the user
    // actually sees it.
    ref.read(aiProvider.notifier).setCardPosition(current);
  }

  /// Card size for the current viewport.
  ///
  /// Desktop keeps the user-resized (and persisted) size. Phones start from
  /// it but clamp to what the viewport can hold with a comfortable margin, so
  /// a 440dp card does not run off a 360dp screen.
  Size _effectiveSize(Size persisted, Size screen, bool compact) {
    if (!compact) return persisted;
    final w = (screen.width - 24).clamp(280.0, persisted.width);
    final h = (screen.height * 0.62).clamp(260.0, screen.height - 96);
    return Size(w, h);
  }

  /// The card's contents: title bar, transcript, input.
  Widget _cardBody(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    double bubbleMax,
    bool streamingHere,
    String? tail,
    List<AiChatMessage> messages,
    String conversation, {
    required bool compact,
  }) {
    return Stack(
      children: [
        Column(
          children: [
            // Title bar: the drag handle (FEATURES 8.4) -- kept off the
            // content area so the input field / messages stay
            // gesture-clean. Styled like the library header: serif
            // title, Fibonacci padding.
            GestureDetector(
              key: const Key('card-drag-handle'),
              behavior: HitTestBehavior.translucent,
              // Dragging works on every platform (FEATURES 8.4). The stored
              // position starts from wherever the card actually is: on a phone
              // the first frame is centred, so `_beginDrag` seeds the state
              // with that origin -- otherwise the first delta would apply to
              // the stale desktop default and teleport the card.
              onPanStart: (_) => _beginDrag(context, ref),
              onPanUpdate: (d) =>
                  ref.read(aiProvider.notifier).moveCard(d.delta),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Golden.s13,
                  Golden.s8,
                  Golden.s4,
                  0,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.sparkles,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: Golden.s8),
                    Text(
                      'AI 结果',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontFamily: 'serif',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    // Stop (while streaming) / copy / expand / close
                    // (6.4.1).
                    if (streamingHere)
                      ToolbarIconButton(
                        icon: LucideIcons.circleStop,
                        tooltip: '停止生成',
                        onTap: () =>
                            ref.read(aiProvider.notifier).cancelStreaming(),
                      ),
                    ToolbarIconButton(
                      icon: LucideIcons.copy,
                      tooltip: '复制对话',
                      onTap: () => copyTextWithSnack(
                        context,
                        conversation,
                        okLabel: '已复制对话',
                      ),
                    ),
                    ToolbarIconButton(
                      icon: LucideIcons.maximize,
                      tooltip: '展开到侧栏',
                      onTap: () =>
                          ref.read(aiProvider.notifier).moveCardToPanel(),
                    ),
                    ToolbarIconButton(
                      icon: LucideIcons.x,
                      tooltip: '关闭',
                      onTap: () => ref.read(aiProvider.notifier).closeCard(),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
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
                            maxWidth: bubbleMax,
                            aiColor: theme.colorScheme.surfaceContainerHighest,
                          ),
                  ...messages.reversed.map(
                    (m) => AiMessageBubble(
                      role: m.role,
                      content: m.content,
                      imagePng: m.imagePng,
                      imagePath: m.imagePath,
                      actionType: m.actionType,
                      createdAt: m.createdAt,
                      maxWidth: bubbleMax,
                      aiColor: theme.colorScheme.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            _CardInput(
              streaming: streamingHere,
              bookId: bookId,
              bookTitle: bookTitle,
            ),
            const SizedBox(height: Golden.s8),
          ],
        ),
        // Bottom-right resize grip (FEATURES 6.4): desktop only -- the
        // phone card is clamped to the viewport, so resizing it would
        // immediately be undone.
        if (!compact)
          Positioned(
            right: 0,
            bottom: 0,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeDownRight,
              child: GestureDetector(
                key: const Key('card-resize-handle'),
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) =>
                    ref.read(panelLayoutProvider.notifier).resizeCard(d.delta),
                onPanEnd: (_) =>
                    ref.read(panelLayoutProvider.notifier).commit(),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    LucideIcons.gripVertical,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
          ),
      ],
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
      final label = m.role == AiRole.user ? '用户' : 'AI';
      final parts = <String>[];
      if (m.actionType != null) {
        parts.add('指令：${aiActionLabel(m.actionType!)}');
      }
      if (m.createdAt != null && m.createdAt!.isNotEmpty) {
        parts.add('时间：${m.createdAt}');
      }
      if (parts.isNotEmpty) sb.writeln(parts.join('  '));
      sb.writeln('$label：${m.content}');
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
class _CardInput extends ConsumerWidget {
  const _CardInput({required this.streaming, this.bookId, this.bookTitle});

  final bool streaming;
  final int? bookId;
  final String? bookTitle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: AiComposerField(
        hint: '输入追问…（Enter 发送）',
        enabled: !streaming,
        maxLines: 3,
        showSendButton: true,
        onSend: (text) => ref
            .read(aiProvider.notifier)
            .sendInput(text, bookId: bookId, bookTitle: bookTitle),
      ),
    );
  }
}

/// Compact icon button for the card header.

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
