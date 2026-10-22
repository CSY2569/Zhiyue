import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/platform/refresh_rate.dart';
import 'package:rbwa/features/reader/providers/bitmap_cache.dart';
import 'package:rbwa/features/bilingual/widgets/translated_text_column.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/phone_reader_chrome.dart';
import 'package:rbwa/platform/platform_host.dart';
import 'package:rbwa/src/rust/api.dart' as rust;

/// Android host.
///
/// Installed by `lib/platform/current.dart` on the `android` branch only:
///  - the Rust core takes the app-support dir the Kotlin bridge exposes,
///  - bundled OCR models are copied out of the APK on first launch,
///  - pdfium is pointed at the app's native library dir,
///  - `onTrimMemory` drops cached page bitmaps before the OS kills us,
///  - reading mode hides the system bars and keeps the screen awake.
class AndroidPlatformHost extends PlatformHost {
  const AndroidPlatformHost();

  @override
  bool get touch => true;

  @override
  bool get needsModelInstall => true;

  @override
  Future<void> prepareWindow() async {
    // Android has no window manager; the system draws the chrome.
  }

  @override
  Future<bool> initCore() async {
    try {
      final dir = await PlatformBridge.filesDir();
      if (dir == null || dir.isEmpty) {
        debugPrint('core init failed: Android filesDir unavailable');
        return false;
      }
      final result = await rust.initCoreWithDataDir(dataDir: dir);

      // pdfium lives in the app's native library dir, which the Rust core
      // cannot discover on its own.
      final libDir = await PlatformBridge.nativeLibraryDir();
      if (libDir != null && libDir.isNotEmpty) {
        try {
          rust.configureNativeLibraryDir(path: libDir);
        } catch (e) {
          debugPrint('configureNativeLibraryDir failed: $e');
        }
      }

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
    // Memory pressure: drop cached page bitmaps before the OS kills the
    // process. The visible page is kept so the reader does not blink.
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

  @override
  Future<BootStatus> ensureModels({
    void Function(double progress, String file)? onProgress,
  }) async {
    final status = await PlatformBridge.ensureOcrModels(
      onProgress: onProgress,
    );
    return BootStatus(
      installed: status.installed,
      error: status.installed ? null : 'OCR 模型安装未完成',
    );
  }

  @override
  Widget wrapApp(Widget child) => RefreshRateScope(child: child);

  @override
  Future<List<String>> takeIncomingFiles() =>
      PlatformBridge.takeIncomingFiles();

  @override
  Widget translatedPane(int bookId) => TranslatedTextColumn(bookId: bookId);

  @override
  ({Widget? top, Widget? bottom}) readerBars(
    BuildContext context,
    WidgetRef ref, {
    required ValueListenable<bool> visibility,
  }) {
    return (
      top: _ChromeFade(
        visible: visibility,
        fromTop: true,
        child: PhoneReaderTopBar(
          onShowMore: () => showPhoneReaderMoreSheet(context, ref),
        ),
      ),
      bottom: _ChromeFade(
        visible: visibility,
        fromTop: false,
        child: PhoneReaderBottomBar(
          onShowMore: () => showPhoneReaderMoreSheet(context, ref),
        ),
      ),
    );
  }

  @override
  Widget wrapReadingSurface({
    required Widget child,
    required ReadingGestures gestures,
  }) =>
      _TouchZoomSurface(gestures: gestures, child: child);

  @override
  Future<void> readerEntered() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await PlatformBridge.setKeepScreenOn(true);
  }

  @override
  Future<void> readerExited() async {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await PlatformBridge.setKeepScreenOn(false);
  }

  @override
  bool handleReaderKey(
    KeyEvent event, {
    required bool editing,
    required VoidCallback nextPage,
    required VoidCallback previousPage,
  }) {
    // Volume keys page the book (a one-hand reading habit). Only while the
    // reading surface has focus and no text field is active -- otherwise the
    // volume keys must keep working normally.
    if (editing) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.audioVolumeDown) {
      nextPage();
      return true;
    }
    if (key == LogicalKeyboardKey.audioVolumeUp) {
      previousPage();
      return true;
    }
    return false;
  }
}

/// Slides + fades one reader bar with the chrome-visibility notifier.
class _ChromeFade extends StatelessWidget {
  const _ChromeFade({
    required this.visible,
    required this.fromTop,
    required this.child,
  });

  final ValueListenable<bool> visible;
  final bool fromTop;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: visible,
      child: child,
      builder: (context, shown, child) => AnimatedSlide(
        offset: shown ? Offset.zero : Offset(0, fromTop ? -1 : 1),
        duration: const Duration(milliseconds: 180),
        child: AnimatedOpacity(
          opacity: shown ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: child,
        ),
      ),
    );
  }
}

/// Pinch-to-zoom / double-tap layer around the page scroll.
///
/// Both callbacks participate in the gesture arena only for their own pointer
/// counts, so single-finger scrolling is unaffected.
class _TouchZoomSurface extends StatelessWidget {
  const _TouchZoomSurface({required this.gestures, required this.child});

  final ReadingGestures gestures;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (d) => gestures.onZoomStart(d.pointerCount),
      onScaleUpdate: (d) => gestures.onZoomUpdate(d.scale, d.pointerCount),
      onDoubleTap: gestures.onDoubleTap,
      child: child,
    );
  }
}
