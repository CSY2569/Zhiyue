import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'package:rbwa/router/app_router.dart';

/// Custom frameless title bar (FEATURES 8.1).
///
/// Replaces the system title bar. Provides:
///   - drag region (move window) via [DragToMoveArea]
///   - centered current title (caller-supplied)
///   - window controls: minimize / maximize-restore / close
///   - a "back to library" affordance when in the reader
///
/// Wired to [WindowManager] which must be initialized in main.dart.
///
/// Note: this widget is rendered inside `MaterialApp.router`'s `builder`,
/// which is *above* the GoRouter sub-tree. Therefore it must not use
/// `context.go()` (no GoRouterState is available); it uses the [appRouter]
/// singleton directly.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    this.title = '智阅',
    this.showBack = false,
  });

  /// Centered title text (book name in reader mode, app name otherwise).
  final String title;

  /// Whether to show the "back to library" button (reader mode).
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      color: theme.colorScheme.surface,
      child: Row(
        children: [
          if (showBack)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 18),
              tooltip: '返回书库',
              onPressed: () => appRouter.go('/library'),
            )
          else
            const SizedBox(width: 8),
          // Drag region fills the space between controls.
          Expanded(
            child: DragToMoveArea(
              child: Center(
                child: Text(
                  title,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          _WindowControls(),
        ],
      ),
    );
  }
}

class _WindowControls extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.colorScheme.onSurface;
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.minimize, size: 18, color: iconColor),
          tooltip: '最小化',
          onPressed: () => windowManager.minimize(),
        ),
        IconButton(
          icon: Icon(Icons.crop_square, size: 16, color: iconColor),
          tooltip: '最大化/还原',
          onPressed: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        IconButton(
          icon: Icon(Icons.close, size: 18, color: iconColor),
          tooltip: '关闭',
          onPressed: () => windowManager.close(),
        ),
      ],
    );
  }
}
