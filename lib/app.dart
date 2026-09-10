import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/router/app_router.dart';

/// Root widget for the RBWA application.
///
/// Wires the theme (8.2/8.3) and the go_router. The frameless title bar is
/// hosted by the router's [ShellRoute] (see `app_router.dart`), which keeps
/// it above the route outlet so it persists across library / reader /
/// settings routes while still reacting to navigation.
class RbwaApp extends ConsumerWidget {
  const RbwaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeControllerProvider);
    return MaterialApp.router(
      title: '智阅',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: appRouter,
    );
  }
}
