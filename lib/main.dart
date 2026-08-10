import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'package:rbwa/app.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/frb_generated.dart';

/// Desktop platforms run the frameless-window shell; mobile (Android) uses
/// the system chrome and gets its data dir from the host.
bool get isDesktop =>
    !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);

/// Application entrypoint.
///
/// Startup sequence (TECH_ROADMAP §1, FEATURES §8.1):
///   1. Flutter bindings + window_manager (frameless, default size, centered).
///      On Android: point the Rust core at the host `filesDir` (Android has
///      no HOME / XDG paths for `dirs::data_dir` to resolve).
///   2. Initialize the flutter_rust_bridge runtime (load the Rust .so).
///   3. Initialize the Rust core: open SQLite, apply schema, set up tracing.
///   4. Hand off to [RbwaApp] which restores persisted settings (theme etc.)
///      and enters the router at /library.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (isDesktop) {
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
  } else {
    // Android: the Rust core stores everything under the app's filesDir.
    final dir = await getApplicationSupportDirectory();
    await rust.setAppDataDir(path: dir.path);
  }

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
