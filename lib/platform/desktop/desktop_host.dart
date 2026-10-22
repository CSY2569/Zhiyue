import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:rbwa/platform/platform_host.dart';
import 'package:rbwa/src/rust/api.dart' as rust;

/// Desktop (Linux / Windows) host.
///
/// Windows are configured through `window_manager`, the Rust core uses the
/// XDG data dir, and no platform channels are involved. Everything else is
/// the shared fallback behaviour.
class DesktopPlatformHost extends PlatformHost {
  const DesktopPlatformHost();

  @override
  bool get touch => false;

  @override
  bool get needsModelInstall => false;

  @override
  Future<void> prepareWindow() async {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1280, 800),
        minimumSize: Size(960, 600),
        center: true,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  @override
  Future<bool> initCore() async {
    try {
      final rust.InitResult result = await rust.initCore();
      if (!result.ok) {
        debugPrint('core init failed: ${result.error}');
        return false;
      }
      debugPrint(
        'core ready: db=${result.dbPath} schema=${result.schemaVersion}',
      );
      return true;
    } catch (e) {
      debugPrint('core init exception: $e');
      return false;
    }
  }

  @override
  void attachLifecycle(ProviderContainer container) {
    // Desktop has no onTrimMemory hook; the byte-budgeted bitmap cache is the
    // only memory guard needed here.
  }
}
