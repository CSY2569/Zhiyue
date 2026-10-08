import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An 8x8 solid-color image for widget tests that need a real [ui.Image]
/// (mirrors the helper in paint_mark_test.dart).
Future<ui.Image> solidTestImage(Color color) {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < 8 * 8; i++) {
    rgba[i * 4] = (color.r * 255).round();
    rgba[i * 4 + 1] = (color.g * 255).round();
    rgba[i * 4 + 2] = (color.b * 255).round();
    rgba[i * 4 + 3] = (color.a * 255).round();
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, 8, 8, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}
