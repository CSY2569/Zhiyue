import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/features/ai/providers/ai_state.dart' show AiThreadState;
import 'package:rbwa/features/ai/widgets/message_bubble.dart' show aiActionIcon;

/// Header above a conversation-window list ("对话窗口").
class AiThreadListHeader extends StatelessWidget {
  const AiThreadListHeader({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        '对话窗口',
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// One row in a conversation-window list: action icon, title and message
/// count. [selected] and [trailing] are optional so the AI side panel and
/// the 「AI 对话」 page share the row without sharing their lifecycle.
class AiThreadTile extends StatelessWidget {
  const AiThreadTile({
    super.key,
    required this.thread,
    required this.onTap,
    this.selected = false,
    this.trailing,
  });

  final AiThreadState thread;
  final VoidCallback onTap;
  final bool selected;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      selected: selected,
      leading: Icon(aiActionIcon(thread.action), size: 20),
      title: Text(thread.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${thread.messages.length} 条消息',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// Compact "no conversations yet" action used by the AI side panel.
class AiHistoryButton extends StatelessWidget {
  const AiHistoryButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(LucideIcons.history, size: 16),
      label: const Text('查看历史对话'),
      style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact),
    );
  }
}
