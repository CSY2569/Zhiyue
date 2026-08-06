import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/features/shell/app_title_bar.dart';
import 'package:rbwa/router/app_router.dart';

/// Root widget for the RBWA application.
///
/// Wires the frameless title bar (FEATURES 8.1), theme (8.2/8.3), and the
/// go_router. The title bar is drawn above the router outlet so it persists
/// across library / reader / settings routes.
class RbwaApp extends ConsumerWidget {
  const RbwaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      title: 'RBWA',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
      builder: (context, child) {
        // The current route decides whether the title bar shows a back button.
        final isReader = GoRouterState.of(context).matchedLocation
            .startsWith('/reader');
        return Column(
          children: [
            AppTitleBar(
              title: isReader ? '阅读器' : 'RBWA',
              showBack: isReader,
            ),
            Expanded(child: child ?? const SizedBox.shrink()),
          ],
        );
      },
    );
  }
}
