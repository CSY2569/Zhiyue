import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/app.dart';
import 'package:rbwa/platform/current.dart';
import 'package:rbwa/platform/platform_host.dart';
import 'package:rbwa/src/rust/frb_generated.dart';

/// Application entrypoint.
///
/// Startup sequence (TECH_ROADMAP §1, FEATURES §8.1):
///   0. Install the platform host and let it configure the window.
///   1. Initialize the flutter_rust_bridge runtime (load the Rust .dylib/.so).
///   2. Initialize the Rust core: open SQLite, apply schema, set up tracing.
///   3. Platforms that ship models inside the package (Android) install them
///      on first launch behind a progress screen, then hand off to [RbwaApp].
///
/// This file is intentionally platform-neutral: every difference lives behind
/// [PlatformHost]. That keeps `main()` byte-identical on the desktop and
/// Android branches, so merges never touch it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PlatformHost.install(platformHost);
  final host = PlatformHost.current;

  await host.prepareWindow();

  // Load the Rust dynamic library and wire the FRB runtime.
  await RustLib.init();

  final initResult = await host.initCore();

  // One explicit container so lifecycle callbacks (which live outside the
  // widget tree) can reach providers.
  final container = ProviderContainer();
  host.attachLifecycle(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: _Bootstrap(coreInit: initResult),
    ),
  );
}

/// Shows the first-run OCR model installation while it copies ~210MB out of
/// the installer assets, then swaps in the real app. On platforms that ship
/// models differently (desktop) this is a single frame.
class _Bootstrap extends StatefulWidget {
  const _Bootstrap({required this.coreInit});

  final bool coreInit;

  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  double _progress = 0;
  String _file = '';
  String? _error;
  late bool _ready;

  @override
  void initState() {
    super.initState();
    _ready = !PlatformHost.current.needsModelInstall;
    if (!_ready) _install();
  }

  Future<void> _install() async {
    try {
      final status = await PlatformHost.current.ensureModels(
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
          _error = status.error ?? 'OCR 模型安装未完成';
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
