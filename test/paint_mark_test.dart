import 'dart:async' show Completer;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/widgets/image_mark_layer.dart'
    show paintMark;

/// Renders [mark] through [paintMark] and returns the raw RGBA pixels of a
/// 200x200 canvas (same path as the live layer and the merged export).
Future<Uint8List> _render(ImageMark mark, {ui.Image? stampImage}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paintMark(canvas, const Size(200, 200), mark, stampImage: stampImage);
  final picture = recorder.endRecording();
  final image = await picture.toImage(200, 200);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  return bytes!.buffer.asUint8List();
}

/// A solid [color] 8x8 image.
Future<ui.Image> _solidImage(Color color) async {
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

bool _pixelIs(Uint8List rgba, int x, int y, Color color) {
  final i = (y * 200 + x) * 4;
  return rgba[i] == (color.r * 255).round() &&
      rgba[i + 1] == (color.g * 255).round() &&
      rgba[i + 2] == (color.b * 255).round();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('stamp image paints exactly over its rect (rotation 0)', () async {
    final image = await _solidImage(const Color(0xFFE53935));
    // Stamp at normalized center (0.5, 0.5), size 0.25 of a 200px canvas
    // -> rect [75..125] on both axes.
    final mark = ImageMark(
      page: 0,
      kind: ImageMarkKind.stamp,
      x: 0.5,
      y: 0.5,
      w: 0.25,
      h: 0.25,
      payload: stampPayload('/tmp/x.png'),
      style: '{}',
    );
    final rgba = await _render(mark, stampImage: image);

    // The painted stamp must coincide with the mark's normalized rect.
    var minX = 999, minY = 999, maxX = -1, maxY = -1;
    for (var y = 0; y < 200; y++) {
      for (var x = 0; x < 200; x++) {
        if (_pixelIs(rgba, x, y, const Color(0xFFE53935))) {
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    expect(minX, 75, reason: 'stamp must start at the rect left edge');
    expect(minY, 75, reason: 'stamp must start at the rect top edge');
    expect(maxX, 124, reason: 'stamp must end at the rect right edge');
    expect(maxY, 124, reason: 'stamp must end at the rect bottom edge');
  });

  test('stamp stays over its rect after rotation', () async {
    final image = await _solidImage(const Color(0xFF43A047));
    final mark = ImageMark(
      page: 0,
      kind: ImageMarkKind.stamp,
      x: 0.5,
      y: 0.5,
      w: 0.25,
      h: 0.25,
      rotation: 0.785398, // 45°
      payload: stampPayload('/tmp/x.png'),
      style: '{}',
    );
    final rgba = await _render(mark, stampImage: image);

    // Center stays covered; a point still inside the rotated square (e.g.
    // 20px above center) must be the stamp color.
    expect(_pixelIs(rgba, 100, 100, const Color(0xFF43A047)), isTrue);
    expect(_pixelIs(rgba, 100, 80, const Color(0xFF43A047)), isTrue);
  });

  test('sticky paints its box at the rect', () async {
    final mark = ImageMark(
      page: 0,
      kind: ImageMarkKind.sticky,
      x: 0.25,
      y: 0.75,
      w: 0.3,
      h: 0.1,
      payload: stickyPayload('hi'),
      style: const ImageMarkStyle(color: '#1e88e5').toJson(),
    );
    final rgba = await _render(mark);
    // Sticky center is covered by the tinted background (alpha > 0).
    final i = (150 * 200 + 50) * 4;
    expect(rgba[i + 3], greaterThan(0), reason: 'sticky box must be painted');
  });
}
