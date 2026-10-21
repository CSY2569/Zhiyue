import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/platform/refresh_rate.dart';
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
  /// normal import path if something is wrong with the file.
  Future<void> _importIncomingFiles() async {
    if (!PlatformBridge.isAndroid) return;
    try {
      final paths = await PlatformBridge.takeIncomingFiles();
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background: drop the refresh-rate hint and stop the activity timer; the
    // OS is not compositing us anyway.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      RefreshRateController.instance.goIdle();
    }
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
      // Refresh-rate policy (Android): any pointer or scroll activity asks
      // the panel for its top rate; going idle drops it to 30Hz. Wrapping the
      // whole app catches every screen without per-widget wiring.
      builder: (context, child) => RefreshRateScope(child: child),
    );
  }
}

/// Feeds pointer/scroll activity into [RefreshRateController].
///
/// A [Listener] catches direct touches; [NotificationListener] catches scroll
/// notifications that bubble up from lists. Both only bump a timer, so the
/// cost per event is a microsecond-scale check -- no rebuilds.
class RefreshRateScope extends StatefulWidget {
  const RefreshRateScope({super.key, required this.child});

  final Widget? child;

  @override
  State<RefreshRateScope> createState() => _RefreshRateScopeState();
}

class _RefreshRateScopeState extends State<RefreshRateScope> {
  @override
  void initState() {
    super.initState();
    RefreshRateController.instance.init();
  }

  @override
  void dispose() {
    RefreshRateController.instance.goIdle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => RefreshRateController.instance.notifyActivity(),
      onPointerMove: (_) => RefreshRateController.instance.notifyActivity(),
      onPointerSignal: (_) => RefreshRateController.instance.notifyActivity(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          RefreshRateController.instance.notifyActivity();
          return false;
        },
        child: widget.child ?? const SizedBox.shrink(),
      ),
    );
  }
}
