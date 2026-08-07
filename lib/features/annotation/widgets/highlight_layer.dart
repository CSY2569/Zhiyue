import 'package:flutter/material.dart';

import 'package:rbwa/src/rust/models/annotation.dart';

/// Parse a '#RRGGBB' hex string into a [Color]; null when unparseable.
Color? parseHexColor(String? hex) {
  if (hex == null || hex.length != 7 || !hex.startsWith('#')) return null;
  final v = int.tryParse(hex.substring(1), radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Encode a [Color] as '#RRGGBB' for persistence (FEATURES 4.3.4 stores
/// colors with the mark).
String colorToHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

/// Paint one page's text-layer marks (FEATURES 4.3): highlight fill, underline
/// along the rect bottom, strikethrough across the middle. Notes draw a light
/// outline so their tappable area is visible. Wrapped in [IgnorePointer] so
/// the layer never intercepts selection gestures.
class HighlightLayer extends StatelessWidget {
  const HighlightLayer({super.key, required this.annotations});

  /// Annotations of the page being drawn (their `page` must match).
  final List<TextAnnotation> annotations;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _HighlightPainter(
          annotations,
          Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _HighlightPainter extends CustomPainter {
  _HighlightPainter(this.annotations, this.fallbackColor);

  final List<TextAnnotation> annotations;
  final Color fallbackColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    for (final ann in annotations) {
      final color = parseHexColor(ann.color) ?? fallbackColor;
      final fillPaint = Paint()..color = color.withValues(alpha: 0.4);
      final linePaint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.square;
      final notePaint = Paint()
        ..color = color.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;

      for (final r in ann.rects) {
        final rect = Rect.fromLTWH(
          r.x * size.width,
          r.y * size.height,
          r.w * size.width,
          r.h * size.height,
        );
        switch (ann.kind) {
          case TextAnnotationKind.highlight:
            canvas.drawRect(rect, fillPaint);
          case TextAnnotationKind.underline:
            canvas.drawLine(rect.bottomLeft, rect.bottomRight, linePaint);
          case TextAnnotationKind.strikethrough:
            canvas.drawLine(
              Offset(rect.left, rect.center.dy),
              Offset(rect.right, rect.center.dy),
              linePaint,
            );
          case TextAnnotationKind.note:
            canvas.drawRect(rect, notePaint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HighlightPainter old) =>
      old.annotations != annotations || old.fallbackColor != fallbackColor;
}
