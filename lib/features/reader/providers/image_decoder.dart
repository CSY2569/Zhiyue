import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Decode raw RGBA bytes (`width * height * 4`) into a [ui.Image].
///
/// Shared by the page-bitmap and thumbnail caches. Wraps the engine's
/// asynchronous decode callback in a Future.
Future<ui.Image?> decodeRgbaImage(int width, int height, Uint8List rgba) {
  final completer = Completer<ui.Image?>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
