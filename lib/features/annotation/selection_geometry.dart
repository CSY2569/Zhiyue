import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Pure selection geometry over CharBox lists (FEATURES 4.1.1).
///
/// All coordinates are *normalized* [0,1] with a top-left origin (the Rust
/// side flips pdfium's bottom-left origin), so hit-testing and rect clustering
/// stay zoom-independent. These functions are deliberately side-effect free so
/// the exact selection behavior is unit-testable.

/// Vertical tolerance when deciding a pointer belongs to a character's line:
/// slightly generous so clicking just above/below a line still selects it.
const double kHitRowTolerance = 0.008;

/// Horizontal distance from point [px] to the closed interval [left, right]
/// (0 when inside).
double _hDistance(double px, double left, double right) {
  if (px < left) return left - px;
  if (px > right) return px - right;
  return 0;
}

/// Index of the character nearest to normalized point [p], or -1 when the
/// point hits a gap between lines (FEATURES 4.1.3: clicking whitespace /
/// line gaps clears the selection). Within a line, gaps between characters
/// snap to the nearest character.
int charIndexAt(List<CharBox> boxes, Offset p) {
  if (boxes.isEmpty) return -1;
  int best = -1;
  double bestDist = double.infinity;
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    // Skip characters whose line does not contain the pointer's y.
    final dy = (p.dy - (b.y + b.h / 2)).abs();
    if (dy > b.h / 2 + kHitRowTolerance) continue;
    final dx = _hDistance(p.dx, b.x, b.x + b.w);
    // Prefer horizontal proximity; vertical distance only breaks ties so a
    // pointer between two lines never picks the wrong one.
    final dist = dx * 4 + dy;
    if (dist < bestDist) {
      bestDist = dist;
      best = i;
    }
  }
  return best;
}

/// Builds the per-line normalized rects covering boxes[start..end] inclusive
/// (FEATURES 4.3.1: 按行精确贴合所选字符). Works for forward and backward
/// selections (the range is normalized internally). Rects are ordered top to
/// bottom. Returns an empty list for an empty range.
///
/// Lines are clustered by *vertical-range overlap* rather than a fixed
/// tolerance: pdfium's tight_bounds tops differ slightly within one visual
/// line when fonts mix (e.g. 'D' at y=0.0860 vs 'u' at y=0.0897 on the same
/// baseline -- a 0.0035 gap that a tolerance would split into two overlapping
/// rects, double-drawing underline/strikethrough marks). Characters on
/// adjacent lines (line gap > 0) never overlap, so they stay separate.
List<NormRect> selectionRects(List<CharBox> boxes, int start, int end) {
  if (boxes.isEmpty) return const [];
  final lo = math.min(start, end).clamp(0, boxes.length - 1);
  final hi = math.max(start, end).clamp(0, boxes.length - 1);

  final lines = <_LineCluster>[];
  for (var i = lo; i <= hi; i++) {
    final b = boxes[i];
    var placed = false;
    for (final line in lines) {
      if (b.y < line.maxY && line.minY < b.y + b.h) {
        line.add(b);
        placed = true;
        break;
      }
    }
    if (!placed) lines.add(_LineCluster(b));
  }
  lines.sort((a, b) => a.minY.compareTo(b.minY));

  return [for (final line in lines) line.rect];
}

/// One visual line being built while clustering: holds the boxes plus the
/// growing vertical range used for the overlap test.
class _LineCluster {
  _LineCluster(CharBox first)
      : boxes = [first],
        minY = first.y,
        maxY = first.y + first.h;

  final List<CharBox> boxes;
  double minY;
  double maxY;

  void add(CharBox b) {
    boxes.add(b);
    minY = math.min(minY, b.y);
    maxY = math.max(maxY, b.y + b.h);
  }

  /// Union rect of the line: left = min x, top = min y, right = max(x+w),
  /// bottom = max(y+h).
  NormRect get rect {
    var minX = double.infinity;
    var maxX = 0.0;
    for (final b in boxes) {
      minX = math.min(minX, b.x);
      maxX = math.max(maxX, b.x + b.w);
    }
    return NormRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY);
  }
}

/// The selected text: characters boxes[start..end] concatenated in document
/// order (independent of drag direction).
String selectionText(List<CharBox> boxes, int start, int end) {
  if (boxes.isEmpty) return '';
  final lo = math.min(start, end).clamp(0, boxes.length - 1);
  final hi = math.max(start, end).clamp(0, boxes.length - 1);
  final buf = StringBuffer();
  for (var i = lo; i <= hi; i++) {
    buf.write(boxes[i].char);
  }
  return buf.toString();
}
