import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/layout_breakpoints.dart';
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart';
import 'package:rbwa/features/reader/widgets/reader_toolbar.dart';
import 'package:rbwa/platform/desktop/desktop_host.dart';

/// Result of a platform bootstrap step (currently: OCR model installation).
class BootStatus {
  const BootStatus({required this.installed, this.error});

  const BootStatus.ready() : installed = true, error = null;

  final bool installed;
  final String? error;
}

/// Reading-surface gestures a platform may wrap the page scroll with.
///
/// Desktop passes nothing (mouse wheel + Ctrl+wheel zoom are handled inside
/// the scroll widget); touch platforms hook pinch-to-zoom and double-tap.
class ReadingGestures {
  const ReadingGestures({
    required this.onZoomStart,
    required this.onZoomUpdate,
    required this.onDoubleTap,
  });

  /// Called with the gesture's pointer count at scale-start.
  final void Function(int pointerCount) onZoomStart;

  /// Called with the cumulative scale and the current pointer count.
  final void Function(double scale, int pointerCount) onZoomUpdate;

  final VoidCallback onDoubleTap;
}

/// The single seam between shared UI and platform-specific behaviour.
///
/// Shared widgets never test `Platform.isAndroid` or `Platform.isIOS`
/// directly. They ask [PlatformHost.current] instead, so the desktop and
/// Android branches can each supply their own implementation while every
/// widget stays byte-identical across the two branches.
///
/// Layout decisions that only depend on the available width (a narrow window
/// on desktop behaves like a phone) are NOT platform differences and stay in
/// the shared widgets as `isCompactWidth`.
abstract class PlatformHost {
  const PlatformHost();

  static PlatformHost _current = const DesktopPlatformHost();

  /// The installed host. [DesktopPlatformHost] by default, so widget tests and
  /// the desktop branch behave identically without extra setup.
  static PlatformHost get current => _current;

  static void install(PlatformHost host) => _current = host;

  /// Touch-first input: haptics, long-press selection, long-press drag.
  bool get touch => false;

  /// Whether the UI should use its compact form at this width: modal panels
  /// instead of side columns, bars instead of a toolbar.
  ///
  /// True on a touch device of ANY width (a landscape tablet keeps the phone
  /// layout, matching the tested behaviour) and on a narrow window of any
  /// platform. The desktop window minimum is 960dp, so this stays false on
  /// desktop in practice.
  bool useCompactLayout(double width) =>
      touch || isCompactWidth(width);

  /// Whether a first-run model install screen is required.
  bool get needsModelInstall => false;

  /// Configure the OS window before the first frame.
  Future<void> prepareWindow() async {}

  /// Initialize the Rust core. Returns false when it is unusable.
  Future<bool> initCore() async => true;

  /// Register process-level callbacks (memory pressure, etc.).
  void attachLifecycle(ProviderContainer container) {}

  /// Make bundled models available. Called only when [needsModelInstall].
  Future<BootStatus> ensureModels({
    void Function(double progress, String file)? onProgress,
  }) async =>
      const BootStatus.ready();

  /// Wrap the whole app (refresh-rate policy, for example).
  Widget wrapApp(Widget child) => child;

  /// Files handed to the app by the OS (Android ACTION_VIEW / ACTION_SEND).
  Future<List<String>> takeIncomingFiles() async => const [];

  /// The 对照 view's right pane for [bookId].
  Widget translatedPane(int bookId) => const TranslatedColumn();

  /// Reader chrome. Either bar may be null.
  ({Widget? top, Widget? bottom}) readerBars(
    BuildContext context,
    WidgetRef ref, {
    required ValueListenable<bool> visibility,
  }) =>
      (top: const ReaderToolbar(), bottom: null);

  /// Wrap the page scroll with platform gestures.
  Widget wrapReadingSurface({
    required Widget child,
    required ReadingGestures gestures,
  }) =>
      child;

  /// Enter / leave full-screen reading (immersive mode, keep screen on).
  Future<void> readerEntered() async {}
  Future<void> readerExited() async {}

  /// Handle a reader key event. Returns true when consumed.
  bool handleReaderKey(
    KeyEvent event, {
    required bool editing,
    required VoidCallback nextPage,
    required VoidCallback previousPage,
  }) =>
      false;
}
