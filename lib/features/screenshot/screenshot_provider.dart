import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui show ImageByteFormat;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/rendering.dart' show OffsetLayer;
import 'package:flutter/widgets.dart'
    show OverlayEntry, OverlayState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';

import 'free_screenshot_overlay.dart';

/// Screenshot lifecycle: idle -> selecting -> capturing -> (vision | preview).
enum ScreenshotPhase { idle, selecting, capturing, preview }

/// UI state of the free-screenshot feature (所选即所得). The capture is the
/// input for the vision model (识图): on success the overlay closes and the
/// PNG goes straight to [AiNotifier.startVision]; the preview phase only
/// surfaces capture failures.
class ScreenshotState {
  const ScreenshotState({
    this.phase = ScreenshotPhase.idle,
    this.start,
    this.current,
    this.error,
  });

  final ScreenshotPhase phase;

  /// Drag start / current pointer positions in window logical coordinates
  /// (the overlay spans the whole window, so its local space == window space).
  final Offset? start;
  final Offset? current;

  /// Non-null when the capture failed (preview phase).
  final String? error;

  /// The selected region, or null before a drag starts.
  Rect? get selection {
    final s = start;
    final c = current;
    if (s == null || c == null) return null;
    return Rect.fromPoints(s, c);
  }

  ScreenshotState copyWith({
    ScreenshotPhase? phase,
    Offset? start,
    Offset? current,
    String? error,
  }) {
    return ScreenshotState(
      phase: phase ?? this.phase,
      start: start ?? this.start,
      current: current ?? this.current,
      error: error ?? this.error,
    );
  }
}

/// Where screenshots are saved (default: `~/Pictures/RBWA`); tests override
/// this so the real filesystem is never touched.
final screenshotOutputDirProvider = Provider<Directory?>((_) => null);

/// Free screenshot: full-window selection overlay, then a literal capture of
/// the window's composited pixels under the selection -- no coordinate
/// mapping anywhere, so 所选即所得 holds by construction.
class ScreenshotNotifier extends Notifier<ScreenshotState> {
  OverlayEntry? _entry;

  /// Book snapshot for the vision action (per-book conversation window,
  /// 6.5.4); captured at [begin] so the notifier never reads the viewer.
  int? _bookId;
  String? _bookTitle;

  /// Drags smaller than this (logical px) are treated as a click -> cancel.
  static const double _minSize = 4;

  @override
  ScreenshotState build() => const ScreenshotState();

  /// Enter screenshot mode: a full-window overlay is inserted above everything.
  /// [bookId] / [bookTitle] snapshot the open book for the vision request.
  void begin(OverlayState overlay, {int? bookId, String? bookTitle}) {
    _bookId = bookId;
    _bookTitle = bookTitle;
    _entry?.remove();
    _entry = OverlayEntry(builder: (_) => const FreeScreenshotOverlay());
    overlay.insert(_entry!);
    state = const ScreenshotState(phase: ScreenshotPhase.selecting);
  }

  /// Pointer down / drag update.
  void updateDrag(Offset start, Offset current) {
    if (state.phase != ScreenshotPhase.selecting) return;
    state = state.copyWith(start: start, current: current);
  }

  /// Pointer released: capture the selection, then hand it straight to the
  /// vision model (识图) -- the answer streams into the result card.
  Future<void> finishDrag(Offset end) async {
    if (state.phase != ScreenshotPhase.selecting) return;
    final sel = state.selection;
    if (sel == null || sel.width < _minSize || sel.height < _minSize) {
      cancel();
      return;
    }
    // Hide the overlay visuals (dim + border) first and capture the frame
    // after it has painted, so the crop is the pristine app underneath --
    // exactly what the user selected. The capturing phase makes the overlay
    // rebuild into an empty (mask-free) surface.
    state = state.copyWith(phase: ScreenshotPhase.capturing);
    try {
      await WidgetsBinding.instance.endOfFrame;
      final shot = await _capturePng(sel);
      if (shot == null) {
        state = state.copyWith(phase: ScreenshotPhase.preview, error: '截图失败');
        return;
      }
      final (png, w, h) = shot;
      // Best-effort save; the vision call only needs the bytes.
      await _savePng(png, w, h);
      // 识图: leave screenshot mode and send the capture to the vision model.
      _teardown();
      await ref.read(aiProvider.notifier).startVision(
            png,
            bookId: _bookId,
            bookTitle: _bookTitle,
          );
    } catch (_) {
      state = state.copyWith(phase: ScreenshotPhase.preview, error: '截图失败');
    }
  }

  /// Leave screenshot mode and remove the overlay.
  void cancel() {
    _teardown();
  }

  void _teardown() {
    _entry?.remove();
    _entry = null;
    state = const ScreenshotState();
  }

  /// Preview card: select another region without leaving screenshot mode.
  void restart() {
    state = const ScreenshotState(phase: ScreenshotPhase.selecting);
  }

  /// Literal screen capture: crops [sel] (window logical coords) out of the
  /// window's composited layer at the native device pixel ratio. The output
  /// is pixel-identical to what the user sees.
  ///
  /// Coordinate caveat: the root layer is a [TransformLayer] that pre-scales
  /// its content by the device pixel ratio (RenderView's
  /// `configuration.toMatrix()`), and `OffsetLayer.toImage` composes its own
  /// scale(pixelRatio) * translate(-bounds) *on top of* that. So bounds must
  /// be given in physical pixels (logical x devicePixelRatio) with
  /// pixelRatio 1.0 -- passing logical bounds with a scaled pixelRatio
  /// silently shifts the crop by (dpr-1) * selection.
  Future<(Uint8List, int, int)?> _capturePng(Rect sel) async {
    final view = WidgetsBinding.instance.renderViews.first;
    // The root layer is the whole window's composited content; `layer` is
    // @protected on RenderObject, but this is the sanctioned way to reach
    // the rendered view.
    // ignore: invalid_use_of_protected_member
    final layer = view.layer;
    if (layer is! OffsetLayer) return null;
    final dpr = view.configuration.devicePixelRatio;
    final logical = sel.intersect(Offset.zero & view.size);
    if (logical.isEmpty || logical.width < 2 || logical.height < 2) {
      return null;
    }
    final bounds = Rect.fromLTWH(
      logical.left * dpr,
      logical.top * dpr,
      logical.width * dpr,
      logical.height * dpr,
    );
    final image = await layer.toImage(bounds, pixelRatio: 1.0);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      return (data.buffer.asUint8List(), image.width, image.height);
    } finally {
      image.dispose();
    }
  }

  /// Best-effort save of [png] as `rbwa_<timestamp>_<w>x<h>.png` under the
  /// output dir (default `~/Pictures/RBWA`); failures are ignored -- the
  /// vision call only needs the bytes.
  Future<void> _savePng(Uint8List png, int w, int h) async {
    try {
      final dir = ref.read(screenshotOutputDirProvider) ?? _defaultDir();
      await dir.create(recursive: true);
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final stamp = '${now.year}${two(now.month)}${two(now.day)}'
          '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final file = File('${dir.path}/rbwa_${stamp}_${w}x$h.png');
      await file.writeAsBytes(png, flush: true);
    } catch (_) {
      // Best-effort: nothing to surface to the reader.
    }
  }

  Directory _defaultDir() {
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory('$home/Pictures/RBWA');
    }
    return Directory('${Directory.systemTemp.path}/RBWA');
  }
}

/// Free-screenshot state.
final screenshotProvider =
    NotifierProvider<ScreenshotNotifier, ScreenshotState>(ScreenshotNotifier.new);
