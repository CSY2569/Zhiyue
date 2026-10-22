import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'package:rbwa/app.dart';
import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/features/reader/providers/bitmap_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/frb_generated.dart';

/// Application entrypoint.
///
/// Startup sequence (TECH_ROADMAP §1, FEATURES §8.1):
///   0. Detect the platform; desktop configures the frameless window while
///      Android resolves its app-support data dir and native library path.
///   1. Initialize the flutter_rust_bridge runtime (load the Rust .so).
///   2. Initialize the Rust core: open SQLite, apply schema, set up tracing.
///   3. Android only: install the bundled OCR models on first launch (with a
///      progress screen), then hand off to [RbwaApp].
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformBridge.init();

  // Desktop: frameless window with default geometry (FEATURES 8.1).
  // Android has no window manager; the system draws the chrome.
  if (!PlatformBridge.isAndroid) {
    await _configureDesktopWindow();
  }

  // Load the Rust dynamic library and wire the FRB runtime.
  await RustLib.init();

  // Rust core init: desktop keeps the XDG data dir; Android must inject the
  // app-support dir because `dirs::data_dir()` is None there and the process
  // CWD is `/`.
  final initResult = await _initCore();

  // Android: point pdfium at the app's native library dir, then make the
  // bundled OCR models available under `{data_dir}/models`.
  if (PlatformBridge.isAndroid) {
    final libDir = await PlatformBridge.nativeLibraryDir();
    if (libDir != null && libDir.isNotEmpty) {
      try {
        rust.configureNativeLibraryDir(path: libDir);
      } catch (e) {
        debugPrint('configureNativeLibraryDir failed: $e');
      }
    }
  }

  // One explicit container so lifecycle callbacks (which live outside the
  // widget tree) can reach providers.
  final container = ProviderContainer();

  // Android memory pressure: drop cached page bitmaps before the OS kills
  // the process. The visible page is kept so the reader does not blink.
  if (PlatformBridge.isAndroid) {
    PlatformBridge.onTrimMemory((level) {
      final page = container.read(viewerProvider).currentPage - 1;
      container.read(bitmapCacheProvider).trim(
            keepPage: page >= 0 ? page : null,
          );
      PaintingBinding.instance.imageCache.clear();
      // Critical: also release decoded thumbnails held by widgets.
      if (level >= 80) {
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    });
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: _Bootstrap(
        coreInit: initResult,
        installModels: PlatformBridge.isAndroid,
      ),
    ),
  );
}

Future<void> _configureDesktopWindow() async {
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

/// Initializes the Rust core and reports failures without crashing the UI.
Future<bool> _initCore() async {
  try {
    final rust.InitResult result;
    if (PlatformBridge.isAndroid) {
      // The Kotlin SystemBridge exposes filesDir; no path_provider needed
      // (that plugin would also pull a JNI runtime into the desktop bundle).
      final dir = await PlatformBridge.filesDir();
      if (dir == null || dir.isEmpty) {
        debugPrint('core init failed: Android filesDir unavailable');
        return false;
      }
      result = await rust.initCoreWithDataDir(dataDir: dir);
    } else {
      result = await rust.initCore();
    }
    if (!result.ok) {
      debugPrint('core init failed: ${result.error}');
      return false;
    }
    debugPrint('core ready: db=${result.dbPath} schema=${result.schemaVersion}');
    return true;
  } catch (e) {
    debugPrint('core init exception: $e');
    return false;
  }
}

/// Shows the first-run OCR model installation while it copies ~210MB out of
/// the APK assets, then swaps in the real app. On every later launch the
/// installer returns immediately and this is a single frame.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.coreInit, required this.installModels});

  final bool coreInit;
  final bool installModels;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  double _progress = 0;
  String _file = '';
  String? _error;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _ready = !widget.installModels;
    if (widget.installModels) {
      _install();
    }
  }

  Future<void> _install() async {
    try {
      final status = await PlatformBridge.ensureOcrModels(
        onProgress: (p, file) {
          if (!mounted) return;
          setState(() {
            _progress = p;
            _file = file;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        if (status.installed) {
          _ready = true;
        } else {
          _error = 'OCR 模型安装未完成';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'OCR 模型安装失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // The Rust core could not be initialized (corrupt database, unwritable
    // data dir, failed migration). Every DB call would panic inside the
    // dynamic library -- and release builds abort the whole process on a
    // panic -- so the app must stop here with a recoverable explanation
    // instead of entering the library and crashing on the first tap.
    if (!widget.coreInit) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(LucideIcons.circleAlert, size: 48),
                  const SizedBox(height: 16),
                  const Text('数据初始化失败', style: TextStyle(fontSize: 18)),
                  const SizedBox(height: 12),
                  const Text(
                    '无法打开本地数据库。请检查磁盘空间与数据目录权限后重启应用；\n'
                    '若问题持续，可备份后删除 ~/.local/share/RBWA/rbwa.db 再启动。',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (_ready) return const RbwaApp();
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('正在安装离线 OCR 模型'),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: _progress == 0 ? null : _progress),
                const SizedBox(height: 12),
                Text(
                  _error ?? '${(_progress * 100).toStringAsFixed(0)}%  $_file',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                        _progress = 0;
                      });
                      _install();
                    },
                    child: const Text('重试'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _ready = true),
                    child: const Text('跳过（暂不使用 OCR）'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
