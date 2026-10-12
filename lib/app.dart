import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/router/app_router.dart';

/// Root widget for the RBWA application.
///
/// Resolves the effective reading theme (FEATURES 8.11) and installs it as
/// the app-wide [MaterialApp] theme -- the library, settings, title bar and
/// reader all follow it. `auto` follows the platform brightness (the legacy
/// `theme` mode key still participates so old dark-mode picks keep working);
/// the [WidgetsBindingObserver] re-resolves when the system switches
/// brightness. The frameless title bar is hosted by the router's
/// [ShellRoute] (see `app_router.dart`), which keeps it above the route
/// outlet so it persists across library / reader / settings routes while
/// still reacting to navigation.
class RbwaApp extends ConsumerStatefulWidget {
  const RbwaApp({super.key});

  @override
  ConsumerState<RbwaApp> createState() => _RbwaAppState();
}

class _RbwaAppState extends ConsumerState<RbwaApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // System light/dark flipped: re-resolve the `auto` reading theme.
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final choice = ref.watch(readingThemeControllerProvider);
    final mode = ref.watch(themeControllerProvider);
    final platform = View.of(context).platformDispatcher.platformBrightness;
    final effective = resolveReadingTheme(choice, mode, platform);
    return MaterialApp.router(
      title: '智阅',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.forReadingTheme(effective),
      routerConfig: appRouter,
    );
  }
}
