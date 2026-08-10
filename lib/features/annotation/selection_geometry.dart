import 'dart:math' as math;
import 'dart:ui' show Offset, TextDirection;

import 'package:flutter/painting.dart' show TextPainter, TextSpan;
import 'package:flutter/services.dart' show TextSelection;

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

// ===========================================================================
// OCR line-level selection (FEATURES 7.1.3): when the char boxes come from
// OCR (one box per recognized line, `char` = the full line text), per-char
// positions are found via TextPainter's full layout engine (kerning-aware).
// This gives precise in-line hit-testing for mixed CJK + Latin + symbols
// without synthesizing fake per-char boxes.
// ===========================================================================

/// A line's pre-computed layout: the source CharBox (normalized rect + full
/// line text) plus a [TextPainter] laid out at its NATURAL width so
/// [TextPainter.getPositionForOffset] can map a pointer x to a character
/// offset within the line.
///
/// The painter is deliberately NOT constrained to the line box width:
/// constraining it (`layout(maxWidth: ...)` with `maxLines: 1`) TRUNCATES the
/// text when the rendered width exceeds the box width, and the truncated
/// tail is never hit-testable -- the second half of a long/mixed line could
/// not be selected. Natural-width layout keeps every character reachable;
/// pointer x beyond the line's box still maps correctly (the painter clamps
/// to the last character).
class LineLayout {
  LineLayout(this.lineBox, this.pageWidthPx)
      : painter = TextPainter(
          text: TextSpan(text: lineBox.char),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        ) {
    painter.layout();
  }

  final CharBox lineBox;
  final double pageWidthPx;
  final TextPainter painter;

  /// The painter's rendered width at natural layout (no maxWidth).
  double get _paintW => painter.width;

  /// The line box's pixel width.
  double get _lineWPx => lineBox.w * pageWidthPx;

  /// Map an in-line pixel x (0 .. line box width) to the painter's coordinate
  /// space using the SAME ratio the display uses (the text layer scales the
  /// text to fill the line box). Without this, hit-testing used the text's
  /// natural width while the overlay showed it scaled to the box -- when the
  /// measured text is narrower than the OCR box, the second half of the
  /// visible line was unreachable ("只能选择前半部分").
  double _toPainterX(double pxInLine) {
    final lineW = _lineWPx;
    final paintW = _paintW;
    if (lineW <= 0 || paintW <= 0) return pxInLine;
    return pxInLine / lineW * paintW;
  }

  /// Character offset within [lineBox.char] at the given normalized x (0..1),
  /// or -1 when the x is outside the line's horizontal span. A pointer at or
  /// beyond the text's end yields the LAST character (getPositionForOffset
  /// returns `text.length` -- an empty range at the end -- which would make
  /// the tail unselectable).
  int charOffsetAt(double normX) {
    final pxInLine = normX * pageWidthPx - lineBox.x * pageWidthPx;
    if (pxInLine < -2) return -1; // left of the line
    final pos = painter
        .getPositionForOffset(Offset(_toPainterX(pxInLine), painter.height / 2));
    final len = lineBox.char.length;
    return pos.offset >= len ? len - 1 : pos.offset;
  }

  /// The normalized x of the left edge of character at [offset] within the
  /// line's text, in DISPLAY space (scaled to the line box, matching the
  /// visible text layer).
  double charLeftNorm(int offset) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    if (boxes.isEmpty) return lineBox.x;
    final paintW = _paintW;
    if (paintW <= 0) return lineBox.x;
    return lineBox.x + boxes.first.left / paintW * lineBox.w;
  }

  /// The normalized x of the right edge of character at [offset], in DISPLAY
  /// space (scaled to the line box).
  double charRightNorm(int offset) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    if (boxes.isEmpty) return lineBox.x + lineBox.w;
    final paintW = _paintW;
    if (paintW <= 0) return lineBox.x + lineBox.w;
    return lineBox.x + boxes.first.right / paintW * lineBox.w;
  }

  void dispose() => painter.dispose();
}

/// Encode a (lineIndex, charOffset) pair into a single int for the
/// Selection model's anchorIndex / currentIndex fields. This avoids changing
/// the Selection model while supporting line-level + in-line positions.
int encodeLinePos(int lineIndex, int charOffset) => lineIndex * 10000 + charOffset;

/// Decode the line index from an encoded position.
int decodeLineIndex(int encoded) => encoded ~/ 10000;

/// Decode the character offset from an encoded position.
int decodeCharOffset(int encoded) => encoded % 10000;

/// Find the line + character offset at normalized point [p]. Returns an
/// encoded position (see [encodeLinePos]), or -1 when the point hits a gap
/// between lines (whitespace).
int lineIndexAt(List<CharBox> boxes, List<LineLayout> layouts, Offset p) {
  if (boxes.isEmpty || layouts.isEmpty) return -1;
  // Find the line whose vertical range contains the pointer's y.
  for (var i = 0; i < boxes.length; i++) {
    final b = boxes[i];
    final dy = (p.dy - (b.y + b.h / 2)).abs();
    if (dy > b.h / 2 + kHitRowTolerance) continue;
    // Found the line; find the in-line character offset.
    final offset = layouts[i].charOffsetAt(p.dx);
    if (offset < 0) return -1;
    return encodeLinePos(i, offset);
  }
  return -1;
}

/// The selected text across a range of encoded positions (line-level boxes).
/// Handles forward and backward selections, and cross-line ranges.
String selectionTextFromLines(
    List<CharBox> boxes, int start, int end) {
  if (boxes.isEmpty) return '';
  final sLine = decodeLineIndex(start);
  final sOff = decodeCharOffset(start);
  final eLine = decodeLineIndex(end);
  final eOff = decodeCharOffset(end);
  // Normalize: lo = earlier in document order, hi = later.
  int loLine, loOff, hiLine, hiOff;
  if (sLine < eLine || (sLine == eLine && sOff <= eOff)) {
    loLine = sLine; loOff = sOff; hiLine = eLine; hiOff = eOff;
  } else {
    loLine = eLine; loOff = eOff; hiLine = sLine; hiOff = sOff;
  }
  final buf = StringBuffer();
  for (var i = loLine; i <= hiLine; i++) {
    final text = boxes[i].char;
    if (i == loLine && i == hiLine) {
      // Single line: substring [loOff, hiOff].
      buf.write(text.substring(
          loOff.clamp(0, text.length), (hiOff + 1).clamp(0, text.length)));
    } else if (i == loLine) {
      buf.write(text.substring(loOff.clamp(0, text.length)));
    } else if (i == hiLine) {
      buf.write(text.substring(0, (hiOff + 1).clamp(0, text.length)));
    } else {
      buf.write(text);
    }
  }
  return buf.toString();
}

/// Per-line normalized rects for the range [start, end] (encoded positions),
/// using the [LineLayout]'s precise per-character x positions. One rect per
/// selected line segment, ordered top to bottom.
List<NormRect> selectionRectsFromLines(
    List<CharBox> boxes, List<LineLayout> layouts, int start, int end) {
  if (boxes.isEmpty || layouts.isEmpty) return const [];
  final sLine = decodeLineIndex(start);
  final sOff = decodeCharOffset(start);
  final eLine = decodeLineIndex(end);
  final eOff = decodeCharOffset(end);
  // Normalize.
  int loLine, loOff, hiLine, hiOff;
  if (sLine < eLine || (sLine == eLine && sOff <= eOff)) {
    loLine = sLine; loOff = sOff; hiLine = eLine; hiOff = eOff;
  } else {
    loLine = eLine; loOff = eOff; hiLine = sLine; hiOff = sOff;
  }
  final rects = <NormRect>[];
  for (var i = loLine; i <= hiLine; i++) {
    final layout = layouts[i];
    final b = boxes[i];
    int from, to;
    if (i == loLine && i == hiLine) {
      from = loOff; to = hiOff;
    } else if (i == loLine) {
      from = loOff; to = b.char.length - 1;
    } else if (i == hiLine) {
      from = 0; to = hiOff;
    } else {
      from = 0; to = b.char.length - 1;
    }
    from = from.clamp(0, b.char.length - 1);
    to = to.clamp(0, b.char.length - 1);
    if (from > to) continue;
    final left = layout.charLeftNorm(from);
    final right = layout.charRightNorm(to);
    rects.add(NormRect(
      x: left,
      y: b.y,
      w: right - left,
      h: b.h,
    ));
  }
  return rects;
}

/// Whether [boxes] are line-level (OCR) boxes: at least one box's `char` has
/// more than one character. Native PDF boxes have one char per box.
bool isLineLevelBoxes(List<CharBox> boxes) {
  for (final b in boxes) {
    if (b.char.length > 1) return true;
  }
  return false;
}
