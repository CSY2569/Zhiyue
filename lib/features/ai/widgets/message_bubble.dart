import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import 'package:rbwa/features/ai/widgets/ai_utils.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// One AI conversation message bubble: user turns right-aligned, AI answers
/// as Markdown on the left (shared by the reader side panel, the result card
/// and the 「AI 对话」 page). Vision turns also show the screenshot that was
/// sent (识图); clicking it pops the image up at full size. Right-click /
/// long-press copies that single message.
class AiMessageBubble extends StatelessWidget {
  const AiMessageBubble({
    super.key,
    required this.role,
    required this.content,
    this.imagePng,
    this.imagePath,
    this.streaming = false,
    this.maxWidth = 260,
    this.aiColor,
  });

  final AiRole role;
  final String content;
  /// In-memory screenshot of the live vision turn.
  final Uint8List? imagePng;
  /// Persisted screenshot restored from history (absolute file path).
  final String? imagePath;
  final bool streaming;
  final double maxWidth;

  /// Background of AI (assistant) bubbles; defaults to the theme's
  /// `surfaceContainerHigh`. The result card passes its own tone.
  final Color? aiColor;

  /// Right-click copies the whole message (desktop; long-press on touch).
  Future<void> _copy(BuildContext context) =>
      copyTextWithSnack(context, content, okLabel: '已复制该消息');

  /// The screenshot widget (live PNG or the persisted file).
  Widget _buildImage() {
    if (imagePng != null) {
      return Image.memory(imagePng!, fit: BoxFit.contain);
    }
    return Image.file(
      File(imagePath!),
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) =>
          const Icon(Icons.broken_image_outlined, color: Colors.black45),
    );
  }

  /// Popup the screenshot at full size (click the bubble image to reopen).
  Future<void> _showImageDialog(BuildContext context) {
    final image = _buildImage();
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(24),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: InteractiveViewer(
            maxScale: 8,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900, maxHeight: 650),
              child: image,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = role == AiRole.user;
    final image = imagePng != null || imagePath != null ? _buildImage() : null;
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
                : (aiColor ?? theme.colorScheme.surfaceContainerHigh),
            borderRadius: BorderRadius.circular(8),
          ),
          child: isUser
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (image != null) ...[
                      GestureDetector(
                        onTap: () => _showImageDialog(context),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: SizedBox(
                              width: 220,
                              height: 150,
                              child: image,
                            ),
                          ),
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
