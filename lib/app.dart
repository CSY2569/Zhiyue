import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/platform/platform_host.dart';
import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
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
  /// Lets lifecycle callbacks (which run outside any page) show a SnackBar.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _importIncomingFiles();
  }

  /// Files delivered by ACTION_VIEW / ACTION_SEND (Android): import them once
  /// the library provider is ready. Failures are silent -- the user sees the
  /// normal import path if something is wrong with the file. Desktop hosts
  /// return an empty list, so this is a no-op there.
  Future<void> _importIncomingFiles() async {
    try {
      final paths = await PlatformHost.current.takeIncomingFiles();
      if (paths.isEmpty || !mounted) return;
      final summary =
          await ref.read(libraryBooksProvider.notifier).importFiles(paths);
      if (!mounted) return;
      final parts = <String>[];
      if (summary.imported > 0) parts.add('导入 ${summary.imported} 本');
      if (summary.alreadyExisted > 0) parts.add('已存在 ${summary.alreadyExisted} 本');
      if (summary.failed > 0) parts.add('失败 ${summary.failed} 本');
      if (parts.isNotEmpty) {
        _messengerKey.currentState
            ?.showSnackBar(SnackBar(content: Text(parts.join('，'))));
      }
    } catch (e) {
      debugPrint('incoming import failed: $e');
    }
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
      scaffoldMessengerKey: _messengerKey,
      // Platform wrapper: on Android this installs the refresh-rate policy
      // (panel top rate while active, 30Hz when idle); desktop passes through.
      builder: (context, child) => PlatformHost.current.wrapApp(child!),
    );
  }
}

