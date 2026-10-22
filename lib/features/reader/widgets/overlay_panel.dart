import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

/// Full-surface panel frame for narrow layouts: a title row with a close
/// button above the panel's own content. Mirrors the side panel's role while
/// keeping the whole width/height available. Used whenever the window is too
/// narrow for a side column -- on a phone and on a narrow desktop window
/// alike, so it carries no platform logic.
class OverlayPanel extends StatelessWidget {
  const OverlayPanel({
    super.key,
    required this.title,
    required this.onClose,
    required this.child,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              IconButton(
                tooltip: '关闭',
                icon: const Icon(LucideIcons.x, size: 20),
                onPressed: onClose,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: child),
      ],
    );
  }
}
