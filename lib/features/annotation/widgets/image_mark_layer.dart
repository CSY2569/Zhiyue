import 'dart:io' show File;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart'
    show parseHexColor;

/// Paint one image-layer mark onto [canvas] (FEATURES 5.1-5.4), scaling the
/// normalized coordinates by [size]. Shared by the live layer and the merged
/// export (5.6), so exported marks look exactly like the on-screen ones.
void paintMark(
  Canvas canvas,
  Size size,
  ImageMark mark, {
  ui.Image? stampImage,
  bool selected = false,
}) {
  final style = mark.styleObj;
  final stroke = style.color == null
      ? null
      : parseHexColor(style.color) ?? const Color(0xFFE53935);
  final paint = Paint()
    ..color = stroke ?? const Color(0xFFE53935)
    ..strokeWidth = style.strokeWidth
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = style.fill ? PaintingStyle.fill : PaintingStyle.stroke;

  switch (mark.kind) {
    case ImageMarkKind.brush:
      final path = Path();
      final points = mark.brushPoints;
      for (var i = 0; i < points.length; i++) {
        final p = Offset(points[i].dx * size.width, points[i].dy * size.height);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (points.isNotEmpty) {
        canvas.drawPath(path, paint..style = PaintingStyle.stroke);
      }
    case ImageMarkKind.shape:
      final rect = _normRect(mark, size);
      final type = mark.shapeType ?? 'rect';
      if (type == 'ellipse') {
        canvas.drawOval(rect, paint);
      } else if (type == 'arrow') {
        _drawArrow(canvas, rect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    case ImageMarkKind.sticky:
      final rect = _normRect(mark, size);
      final text = mark.stickyText ?? '';
      final bg = Paint()
        ..color = (stroke ?? const Color(0xFFE53935)).withValues(alpha: 0.12);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        bg,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        paint..style = PaintingStyle.stroke,
      );
      if (text.isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(
              fontSize: style.fontSize,
              color: const Color(0xFF212121),
            ),
          ),
          maxLines: 20,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: rect.width - 8);
        tp.paint(canvas, rect.topLeft + const Offset(4, 4));
      }
    case ImageMarkKind.stamp:
      final rect = _normRect(mark, size);
      if (stampImage != null) {
        // Rotate around the rect center; the image is drawn in the local
        // (post-transform) space so it lands exactly on [rect] -- using the
        // absolute rect here would double-offset the stamp.
        canvas.save();
        canvas.translate(rect.center.dx, rect.center.dy);
        canvas.rotate(mark.rotation);
        canvas.drawImageRect(
          stampImage,
          Rect.fromLTWH(
              0, 0, stampImage.width.toDouble(), stampImage.height.toDouble()),
          Rect.fromLTWH(
              -rect.width / 2, -rect.height / 2, rect.width, rect.height),
          Paint(),
        );
        canvas.restore();
      } else {
        // Image not loaded yet: placeholder outline.
        canvas.drawRect(
          rect,
          paint
            ..color = const Color(0x339E9E9E)
            ..style = PaintingStyle.stroke,
        );
      }
  }

  if (selected) {
    final rect = _normRect(mark, size);
    canvas.drawRect(
      rect.inflate(3),
      Paint()
        ..color = const Color(0xFF1E88E5)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    // Corner resize handles.
    for (final corner in _corners(rect)) {
      canvas.drawRect(
        Rect.fromCenter(center: corner, width: 8, height: 8),
        Paint()..color = const Color(0xFF1E88E5),
      );
    }
  }
}

/// Normalized rect (mark center + size) scaled to [size].
Rect _normRect(ImageMark mark, Size size) {
  final w = (mark.w ?? 0.2) * size.width;
  final h = (mark.h ?? 0.2) * size.height;
  return Rect.fromCenter(
    center: Offset(mark.x * size.width, mark.y * size.height),
    width: w,
    height: h,
  );
}

/// Arrow from the rect's left-center to right-center, with a head.
void _drawArrow(Canvas canvas, Rect rect, Paint paint) {
  final start = rect.centerLeft;
  final end = rect.centerRight;
  canvas.drawLine(start, end, paint);
  final angle = (end - start).direction;
  final headLen = (paint.strokeWidth * 4).clamp(10.0, 20.0);
  final head = Paint()
    ..color = paint.color
    ..strokeWidth = paint.strokeWidth
    ..strokeCap = StrokeCap.round;
  for (final da in [0.5, -0.5]) {
    canvas.drawLine(
      end,
      end - Offset.fromDirection(angle + da, headLen),
      head,
    );
  }
}

List<Offset> _corners(Rect r) => [
      r.topLeft,
      r.topRight,
      r.bottomLeft,
      r.bottomRight,
    ];

enum _Corner { topLeft, topRight, bottomLeft, bottomRight }

/// Which corner handle is within [tolerance] of [p] (in [size] space).
_Corner? _hitCorner(Rect rect, Offset p, double tolerance) {
  const corners = {
    _Corner.topLeft: Alignment.topLeft,
    _Corner.topRight: Alignment.topRight,
    _Corner.bottomLeft: Alignment.bottomLeft,
    _Corner.bottomRight: Alignment.bottomRight,
  };
  for (final e in corners.entries) {
    final c = e.value.alongSize(rect.size) + rect.topLeft;
    if ((c - p).distance <= tolerance) return e.key;
  }
  return null;
}

/// The page's mark layer: paints marks and handles the armed tool's pointer
/// events (FEATURES 5.1-5.4). Sits above the selection layer; when no tool
/// is armed it is hit-test transparent so reading gestures pass through.
class ImageMarkLayer extends ConsumerStatefulWidget {
  const ImageMarkLayer({super.key, required this.page});

  /// 0-indexed page this layer belongs to.
  final int page;

  @override
  ConsumerState<ImageMarkLayer> createState() => _ImageMarkLayerState();
}

class _ImageMarkLayerState extends ConsumerState<ImageMarkLayer> {
  // In-progress drawing (normalized coordinates).
  final List<Offset> _brush = [];
  Offset? _shapeStart;
  Offset? _shapeCurrent;

  /// Precise pointer-down point (normalized). `onPanStart` fires only after
  /// the touch slop is crossed, so drawing / dragging must anchor on this
  /// down point instead of the slop-shifted start position.
  Offset? _panDown;

  // Selection / manipulation.
  int? _selectedId;
  Offset? _moveStart; // gesture start (normalized)
  Offset? _markStartPos; // mark position before the gesture
  double? _scaleStartW; // mark size before a resize gesture
  double? _scaleStartH;
  ImageMark? _dragBefore; // mark snapshot before the drag (undo)
  _Corner? _scaleCorner;

  /// Loaded stamp images (absolute file path -> decoded image).
  final Map<String, ui.Image> _stampCache = {};

  @override
  void dispose() {
    for (final img in _stampCache.values) {
      img.dispose();
    }
    super.dispose();
  }

  Future<ui.Image?> _stampImage(String path) async {
    final cached = _stampCache[path];
    if (cached != null) return cached;
    try {
      final img = await decodeImageFromList(await File(path).readAsBytes());
      _stampCache[path] = img;
      if (mounted) setState(() {});
      return img;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final toolState = ref.watch(markToolProvider);
    final tool = toolState.tool;
    final marks = ref.watch(imageMarkProvider).valueOrNull ?? const [];
    final visible = ref.watch(markVisibilityProvider);
    final pageMarks = [
      for (final m in marks)
        if (m.page == widget.page && visible.contains(m.kind)) m,
    ];

    // Kick off async stamp image loads (repaints when each lands).
    for (final m in marks) {
      final file = m.stampFile;
      if (m.kind == ImageMarkKind.stamp && file != null) {
        _stampImage(file);
      }
    }

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      return GestureDetector(
        behavior: tool == null
            ? HitTestBehavior.deferToChild
            : HitTestBehavior.opaque,
        onPanDown: tool == null
            ? null
            : (d) => _onPanDown(d.localPosition, size, toolState),
        onPanStart: tool == null
            ? null
            : (d) => _onPanStart(d.localPosition, size, toolState),
        onPanUpdate: tool == null
            ? null
            : (d) => _onPanUpdate(d.localPosition, size, toolState),
        onPanEnd: tool == null ? null : (d) => _onPanEnd(size, toolState),
        onTapUp: tool == null ? null : (d) => _onTap(d.localPosition, size, toolState),
        onSecondaryTapDown: tool == MarkTool.select
            ? (d) => _onSecondaryTap(d.localPosition, size)
            : null,
        child: CustomPaint(
          size: size,
          painter: _MarkPainter(
            marks: pageMarks,
            brush: List.of(_brush),
            shapeStart: _shapeStart,
            shapeCurrent: _shapeCurrent,
            tool: tool,
            shapeType: toolState.shapeType,
            stampFile: toolState.stampFile,
            selectedId: _selectedId,
            stampImage: (path) => _stampCache[path],
            previewColor:
                parseHexColor(toolState.color) ?? const Color(0xFFE53935),
            previewStrokeWidth: toolState.strokeWidth,
            previewFill: toolState.fill,
          ),
        ),
      );
    });
  }

  Offset _toNorm(Offset local, Size size) =>
      Offset(local.dx / size.width, local.dy / size.height);

  /// Pointer down: record the precise anchor. The select tool also resolves
  /// the hit here (handle -> resize, mark -> move, blank -> deselect), so the
  /// selection follows the exact press point rather than the slop-shifted
  /// pan-start position.
  void _onPanDown(Offset local, Size size, MarkToolState toolState) {
    final p = _toNorm(local, size);
    _panDown = p;
    if (toolState.tool != MarkTool.select) return;

    final marks = _pageMarks;
    ImageMark? selected;
    for (final m in marks) {
      if (m.id == _selectedId) {
        selected = m;
        break;
      }
    }
    if (selected != null) {
      final corner = _hitCorner(_normRect(selected, size), local, 12);
      if (corner != null) {
        setState(() {
          _scaleCorner = corner;
          _dragBefore = selected;
        });
        return;
      }
    }
    final hit = _hitMark(marks, p);
    setState(() {
      _selectedId = hit?.id;
      _dragBefore = hit;
      _scaleCorner = null;
    });
  }

  /// Pan started: anchor the stroke / drag baseline. [local] sits past the
  /// touch slop, so drawing starts at the down point and moving starts with
  /// a zero delta from the mark's current position.
  void _onPanStart(Offset local, Size size, MarkToolState toolState) {
    final p = _toNorm(local, size);
    final down = _panDown;
    switch (toolState.tool) {
      case MarkTool.brush:
        setState(() {
          _brush
            ..clear()
            ..add(down ?? p);
        });
      case MarkTool.shape:
        setState(() {
          _shapeStart = down ?? p;
          _shapeCurrent = p;
        });
      case MarkTool.select:
        final marks = _pageMarks;
        ImageMark? selected;
        for (final m in marks) {
          if (m.id == _selectedId) {
            selected = m;
            break;
          }
        }
        if (selected == null) {
          setState(() {
            _moveStart = null;
            _markStartPos = null;
          });
          break;
        }
        final sel = selected;
        setState(() {
          _moveStart = p; // zero delta at the pan-start position
          _markStartPos = Offset(sel.x, sel.y);
          _scaleStartW = sel.w;
          _scaleStartH = sel.h;
        });
      case MarkTool.sticky:
      case MarkTool.stamp:
      case null:
        break; // tap-placed tools / no tool
    }
  }

  void _onPanUpdate(Offset local, Size size, MarkToolState toolState) {
    final p = _toNorm(local, size);
    switch (toolState.tool) {
      case MarkTool.brush:
        setState(() => _brush.add(p));
      case MarkTool.shape:
        setState(() => _shapeCurrent = p);
      case MarkTool.select:
        // The target follows the pointer relative to the *baseline* recorded
        // at pan start -- never relative to the already-updated list value,
        // which would accumulate the delta on every move and make the mark
        // run away from the cursor.
        final start = _moveStart;
        final startPos = _markStartPos;
        if (start == null || startPos == null) return;
        final delta = p - start;
        if (_scaleCorner != null) {
          final sw = _scaleStartW;
          final sh = _scaleStartH;
          if (sw == null || sh == null) return;
          final newW = (sw + 2 * delta.dx).clamp(0.01, 2.0);
          final newH = (sh + 2 * delta.dy).clamp(0.01, 2.0);
          setState(
              () => _applyDrag(_selectedId!, startPos, w: newW, h: newH));
        } else {
          setState(() => _applyDrag(_selectedId!, startPos + delta));
        }
      case MarkTool.sticky:
      case MarkTool.stamp:
      case null:
        break;
    }
  }

  Future<void> _onPanEnd(Size size, MarkToolState toolState) async {
    switch (toolState.tool) {
      case MarkTool.brush:
        final points = List<Offset>.of(_brush);
        setState(() => _brush.clear());
        if (points.length < 3) return;
        final bounds = _boundsOf(points);
        await _createMark(ImageMark(
          page: widget.page,
          kind: ImageMarkKind.brush,
          x: bounds.center.dx,
          y: bounds.center.dy,
          w: bounds.width,
          h: bounds.height,
          payload: brushPayload(points),
          style: _styleOf(toolState).toJson(),
        ));
      case MarkTool.shape:
        final start = _shapeStart;
        final current = _shapeCurrent;
        setState(() {
          _shapeStart = null;
          _shapeCurrent = null;
        });
        if (start == null || current == null) return;
        final rect = Rect.fromPoints(start, current);
        if (rect.width < 0.01 || rect.height < 0.01) return;
        await _createMark(ImageMark(
          page: widget.page,
          kind: ImageMarkKind.shape,
          x: rect.center.dx,
          y: rect.center.dy,
          w: rect.width,
          h: rect.height,
          payload: shapePayload(toolState.shapeType),
          style: _styleOf(toolState).toJson(),
        ));
      case MarkTool.select:
        // Persist the drag (moves were applied in-memory via _applyDrag).
        ImageMark? moved;
        for (final m in _pageMarks) {
          if (m.id == _selectedId) {
            moved = m;
            break;
          }
        }
        if (moved != null) {
          await ref
              .read(imageMarkProvider.notifier)
              .updateMark(moved, before: _dragBefore);
        }
        setState(() {
          _moveStart = null;
          _markStartPos = null;
          _scaleStartW = null;
          _scaleStartH = null;
          _dragBefore = null;
          _scaleCorner = null;
          _panDown = null;
        });
      case MarkTool.sticky:
      case MarkTool.stamp:
      case null:
        break;
    }
  }

  Future<void> _onTap(Offset local, Size size, MarkToolState toolState) async {
    final p = _toNorm(local, size);
    _panDown = null; // a plain tap never fires onPanEnd; drop the anchor
    switch (toolState.tool) {
      case MarkTool.select:
        final hit = _hitMark(_pageMarks, p);
        setState(() => _selectedId = hit?.id);
      case MarkTool.sticky:
        await _promptSticky(p);
      case null:
        break;
      case MarkTool.stamp:
        final file = toolState.stampFile;
        if (file == null || file.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('请先在工具栏选择图章图片')),
            );
          }
          return;
        }
        await _createMark(ImageMark(
          page: widget.page,
          kind: ImageMarkKind.stamp,
          x: p.dx,
          y: p.dy,
          w: 0.25,
          h: 0.25,
          payload: stampPayload(file),
          style: _styleOf(toolState).toJson(),
        ));
      case MarkTool.brush:
      case MarkTool.shape:
        break;
    }
  }

  void _onSecondaryTap(Offset local, Size size) {
    final p = _toNorm(local, size);
    final hit = _hitMark(_pageMarks, p);
    if (hit == null) return;
    setState(() => _selectedId = hit.id);
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(local.dx, local.dy, local.dx, local.dy),
      items: [
        if (hit.kind == ImageMarkKind.sticky)
          const PopupMenuItem(value: 'edit', child: Text('编辑便签')),
        const PopupMenuItem(value: 'rotate', child: Text('旋转 15°')),
        const PopupMenuItem(value: 'delete', child: Text('删除')),
      ],
    ).then((action) async {
      if (action == null || !mounted) return;
      final notifier = ref.read(imageMarkProvider.notifier);
      switch (action) {
        case 'edit':
          await _promptSticky(Offset(hit.x, hit.y), editing: hit);
        case 'rotate':
          await notifier.updateMark(
            hit.copyWith(rotation: hit.rotation + 15 * 3.14159 / 180),
            before: hit,
          );
        case 'delete':
          await notifier.delete(hit.id);
      }
    });
  }

  Future<void> _promptSticky(Offset pos, {ImageMark? editing}) async {
    final controller = TextEditingController(text: editing?.stickyText ?? '');
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editing == null ? '添加便签' : '编辑便签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(hintText: '便签内容'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || !mounted) return;
    final toolState = ref.read(markToolProvider);
    final style = _styleOf(toolState).toJson();
    if (editing == null) {
      await _createMark(ImageMark(
        page: widget.page,
        kind: ImageMarkKind.sticky,
        x: pos.dx,
        y: pos.dy,
        w: 0.3,
        h: 0.1,
        payload: stickyPayload(text),
        style: style,
      ));
    } else {
      await ref.read(imageMarkProvider.notifier).updateMark(
            editing.copyWith(payload: stickyPayload(text)),
            before: editing,
          );
    }
  }

  /// Update a mark's geometry in the local list (used during drags; the
  /// caller persists on gesture end).
  void _applyDrag(int id, Offset center, {double? w, double? h}) {
    final marks = _pageMarks;
    final idx = marks.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    // Persisted marks live in the provider; we mutate the provider state
    // copy directly so the paint stays in sync during the drag.
    ref.read(imageMarkProvider.notifier).applyLocalDrag(
          id,
          center.dx,
          center.dy,
          w: w,
          h: h,
        );
  }

  ImageMarkStyle _styleOf(MarkToolState toolState) => ImageMarkStyle(
        color: toolState.color,
        strokeWidth: toolState.strokeWidth,
        fill: toolState.fill,
        fontSize: toolState.fontSize,
      );

  List<ImageMark> get _pageMarks =>
      ref.read(imageMarkProvider).valueOrNull?.where((m) => m.page == widget.page).toList() ??
      const [];

  Future<void> _createMark(ImageMark mark) async {
    await ref.read(imageMarkProvider.notifier).create(mark);
  }

  /// First mark whose body contains [p] (normalized); brush marks hit-test
  /// by distance to their path.
  ImageMark? _hitMark(List<ImageMark> marks, Offset p) {
    for (final m in marks) {
      if (m.kind == ImageMarkKind.brush) {
        if (_nearBrush(m, p)) return m;
      } else if (m.containsNorm(p)) {
        return m;
      }
    }
    return null;
  }

  bool _nearBrush(ImageMark m, Offset p) {
    final pts = m.brushPoints;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final d = _distToSegment(p, a, b);
      if (d < 0.02) return true;
    }
    return false;
  }

  double _distToSegment(Offset p, Offset a, Offset b) {
    final ab = b - a;
    final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
    if (len2 == 0) return (p - a).distance;
    var t = ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
    t = t.clamp(0.0, 1.0);
    return (p - (a + ab * t)).distance;
  }
}

Rect _boundsOf(List<Offset> pts) {
  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final p in pts) {
    minX = p.dx < minX ? p.dx : minX;
    minY = p.dy < minY ? p.dy : minY;
    maxX = p.dx > maxX ? p.dx : maxX;
    maxY = p.dy > maxY ? p.dy : maxY;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Paints the page's marks + in-progress drawing (brush path / shape drag).
class _MarkPainter extends CustomPainter {
  _MarkPainter({
    required this.marks,
    required this.brush,
    required this.shapeStart,
    required this.shapeCurrent,
    required this.tool,
    required this.shapeType,
    required this.stampFile,
    required this.selectedId,
    required this.stampImage,
    required this.previewColor,
    required this.previewStrokeWidth,
    required this.previewFill,
  });

  final List<ImageMark> marks;
  final List<Offset> brush;
  final Offset? shapeStart;
  final Offset? shapeCurrent;
  final MarkTool? tool;
  final String shapeType;
  final String? stampFile;
  final int? selectedId;
  final ui.Image? Function(String path) stampImage;

  /// Armed tool's style, used for the live drawing preview (FEATURES 5.5:
  /// the preview must match the chosen color / thickness immediately).
  final Color previewColor;
  final double previewStrokeWidth;
  final bool previewFill;

  @override
  void paint(Canvas canvas, Size size) {
    for (final m in marks) {
      final img = m.kind == ImageMarkKind.stamp && m.stampFile != null
          ? stampImage(m.stampFile!)
          : null;
      paintMark(canvas, size, m,
          stampImage: img, selected: m.id == selectedId);
    }

    // In-progress brush stroke (the armed tool's live preview).
    if (tool == MarkTool.brush && brush.length >= 2) {
      final path = Path();
      for (var i = 0; i < brush.length; i++) {
        final p = Offset(brush[i].dx * size.width, brush[i].dy * size.height);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = previewColor
          ..strokeWidth = previewStrokeWidth
          ..strokeCap = StrokeCap.round
          ..style = PaintingStyle.stroke,
      );
    }

    // In-progress shape drag.
    if (tool == MarkTool.shape && shapeStart != null && shapeCurrent != null) {
      final rect = Rect.fromPoints(
        Offset(shapeStart!.dx * size.width, shapeStart!.dy * size.height),
        Offset(shapeCurrent!.dx * size.width, shapeCurrent!.dy * size.height),
      );
      final paint = Paint()
        ..color = previewColor
        ..strokeWidth = previewStrokeWidth
        ..style = previewFill ? PaintingStyle.fill : PaintingStyle.stroke;
      if (shapeType == 'ellipse') {
        canvas.drawOval(rect, paint);
      } else if (shapeType == 'arrow') {
        _drawArrow(canvas, rect, paint);
      } else {
        canvas.drawRect(rect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_MarkPainter old) =>
      old.marks != marks ||
      old.brush != brush ||
      old.shapeStart != shapeStart ||
      old.shapeCurrent != shapeCurrent ||
      old.tool != tool ||
      old.shapeType != shapeType ||
      old.stampFile != stampFile ||
      old.selectedId != selectedId ||
      old.previewColor != previewColor ||
      old.previewStrokeWidth != previewStrokeWidth ||
      old.previewFill != previewFill;
}
