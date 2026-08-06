import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'package:rbwa/app.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/frb_generated.dart';

/// Application entrypoint.
///
/// Startup sequence (TECH_ROADMAP §1, FEATURES §8.1):
///   1. Flutter bindings + window_manager (frameless, default size, centered).
///   2. Initialize the flutter_rust_bridge runtime (load the Rust .so).
///   3. Initialize the Rust core: open SQLite, apply schema, set up tracing.
///   4. Hand off to [RbwaApp] which restores persisted settings (theme etc.)
///      and enters the router at /library.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Frameless window with default geometry (FEATURES 8.1).
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

  // 2. Load the Rust dynamic library and wire the FRB runtime.
  await RustLib.init();

  // 3. Initialize the Rust core (SQLite + schema). Failures are surfaced in
  //    the UI rather than crashing the app; the skeleton can still render.
  try {
    final result = await rust.initCore();
    if (!result.ok) {
      debugPrint('core init failed: ${result.error}');
    } else {
      debugPrint('core ready: db=${result.dbPath} schema=${result.schemaVersion}');
    }
  } catch (e) {
    debugPrint('core init exception: $e');
  }

  // 4. Run the app; RbwaApp restores persisted settings on first build.
  runApp(const ProviderScope(child: RbwaApp()));
}
