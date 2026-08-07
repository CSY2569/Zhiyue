import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:rbwa/src/rust/models/ai.dart';

/// One AI conversation message bubble: user turns right-aligned, AI answers
/// as Markdown on the left (shared by the reader side panel and the
/// 「AI 对话」 page). Vision turns also show the screenshot that was sent
/// (识图). Right-click / long-press copies that single message.
class AiMessageBubble extends StatelessWidget {
  const AiMessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.imagePng,
    this.streaming = false,
    this.maxWidth = 260,
  });

  final AiRole role;
  final String content;
  final Uint8List? imagePng;
  final bool streaming;
  final double maxWidth;

  /// Right-click copies the whole message (desktop; long-press on touch).
  Future<void> _copy(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Clipboard.setData(ClipboardData(text: content));
      messenger.showSnackBar(const SnackBar(content: Text('已复制该消息')));
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('复制失败')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = role == AiRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onSecondaryTapDown: (_) => _copy(context),
        onLongPress: () => _copy(context),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          constraints: BoxConstraints(maxWidth: maxWidth),
          decoration: BoxDecoration(
            color: isUser
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(8),
          ),
          child: isUser
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (imagePng != null) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: ConstrainedBox(
                          constraints:
                              const BoxConstraints(maxWidth: 240, maxHeight: 180),
                          child: Image.memory(imagePng!, fit: BoxFit.contain),
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    Text(content, style: theme.textTheme.bodySmall),
                  ],
                )
              : MarkdownBody(
                  // GFM is the default extension set.
                  data: streaming ? '$content\n\n▍' : content,
                  styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                    p: theme.textTheme.bodySmall,
                    codeblockDecoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

/// Icon of the latest action performed in a conversation window (history
/// list / 「AI 对话」 page).
IconData aiActionIcon(AiActionType action) {
  switch (action) {
    case AiActionType.translate:
      return Icons.translate;
    case AiActionType.explain:
      return Icons.lightbulb_outline;
    case AiActionType.search:
      return Icons.search;
    case AiActionType.chat:
      return Icons.chat_outlined;
    case AiActionType.vision:
      return Icons.document_scanner_outlined;
  }
}
