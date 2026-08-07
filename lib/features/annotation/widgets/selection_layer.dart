import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/src/rust/models/annotation.dart';
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Pointer layer on top of one page: drag to select characters (FEATURES
/// 4.1), tap a mark to open its note (FEATURES 4.4.2), tap whitespace to
/// clear (FEATURES 4.1.3). Also paints the live selection preview.
///
/// Hit-testing runs against the page's CharBoxes in *normalized* coordinates
/// (scaled from the layer's own size), so it stays correct at any zoom. The
/// char boxes are preloaded on init / page change so the first drag works
/// immediately.
class SelectionLayer extends ConsumerStatefulWidget {
  const SelectionLayer({
    super.key,
    required this.bookId,
    required this.page, // 0-indexed
    required this.annotations, // annotations of this page
  });

  final int bookId;
  final int page;
  final List<TextAnnotation> annotations;

  @override
  ConsumerState<SelectionLayer> createState() => _SelectionLayerState();
}

class _SelectionLayerState extends ConsumerState<SelectionLayer> {
  // Char index where the current drag started; null while not dragging.
  int? _dragAnchor;
  // Pointer-down position (local). DragStartDetails.localPosition is only
  // resolved once the gesture passes the touch slop, so the anchor must come
  // from onPanDown to keep the selection starting exactly where the user
  // pressed.
  Offset? _dragDownPos;

  @override
  void initState() {
    super.initState();
    _preloadBoxes();
  }

  @override
  void didUpdateWidget(SelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.bookId != widget.bookId) {
      _preloadBoxes();
    }
  }

  /// Kick off the char-box load (the selection's data). The provider update
  /// rebuilds this layer once the boxes arrive. Runs post-frame so it never
  /// mutates providers during build.
  void _preloadBoxes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(charBoxCacheProvider.notifier)
          .getOrFetch(widget.bookId, widget.page);
    });
  }

  List<CharBox>? get _boxes =>
      ref.watch(charBoxCacheProvider.select((m) => m[widget.page]));

  /// Convert a local pointer position to normalized page coordinates.
  Offset _toNorm(Offset local) {
    final render = context.findRenderObject() as RenderBox?;
    final size = render?.size ?? Size.zero;
    if (size.isEmpty) return Offset.zero;
    return Offset(
      (local.dx / size.width).clamp(0.0, 1.0),
      (local.dy / size.height).clamp(0.0, 1.0),
    );
  }

  void _setSelection(int idx) {
    final boxes = _boxes;
    final anchor = _dragAnchor;
    if (boxes == null || anchor == null) return;
    final sel = Selection(
      page: widget.page,
      anchorIndex: anchor,
      currentIndex: idx,
      text: selectionText(boxes, anchor, idx),
      lineRects: selectionRects(boxes, anchor, idx),
    );
    ref.read(selectionProvider.notifier).updateSelection(sel);
  }

  void _onPanDown(DragDownDetails d) => _dragDownPos = d.localPosition;

  void _onPanStart(DragStartDetails d) {
    final boxes = _boxes;
    if (boxes == null) {
      // Char boxes not loaded yet -- kick off the fetch; the provider update
      // rebuilds this layer and the next drag works.
      _preloadBoxes();
      return;
    }
    if (boxes.isEmpty) return; // no text layer on this page
    final idx = charIndexAt(boxes, _toNorm(_dragDownPos ?? d.localPosition));
    if (idx < 0) {
      // Drag began in whitespace: nothing to select.
      ref.read(selectionProvider.notifier).clear();
      return;
    }
    _dragAnchor = idx;
    _setSelection(idx);
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final boxes = _boxes;
    if (boxes == null || _dragAnchor == null) return;
    final idx = charIndexAt(boxes, _toNorm(d.localPosition));
    if (idx < 0) return; // pointer left the text grid; keep last range
    _setSelection(idx);
  }

  void _onPanEnd(DragEndDetails d) {
    _dragDownPos = null;
    if (_dragAnchor == null) return;
    _dragAnchor = null;
    // Anchor the floating toolbar above the selection's first line, in
    // global coordinates (the toolbar lives in an Overlay).
    final sel = ref.read(selectionProvider).selection;
    if (sel == null || sel.page != widget.page || sel.lineRects.isEmpty) {
      return;
    }
    final render = context.findRenderObject() as RenderBox?;
    if (render == null || render.size.isEmpty) return;
    final origin = render.localToGlobal(Offset.zero);
    final size = render.size;
    final first = sel.lineRects.first;
    ref.read(selectionProvider.notifier).commitSelection(
          sel,
          Rect.fromLTWH(
            origin.dx + first.x * size.width,
            origin.dy + first.y * size.height,
            first.w * size.width,
            first.h * size.height,
          ),
        );
  }

  /// The annotation whose rects contain the tap (FEATURES 4.4.2).
  TextAnnotation? _annotationAt(Offset norm) {
    for (final ann in widget.annotations) {
      for (final r in ann.rects) {
        if (norm.dx >= r.x &&
            norm.dx <= r.x + r.w &&
            norm.dy >= r.y &&
            norm.dy <= r.y + r.h) {
          return ann;
        }
      }
    }
    return null;
  }

  void _onTapUp(TapUpDetails d) {
    final size = (context.findRenderObject() as RenderBox?)?.size ?? Size.zero;
    if (size.isEmpty) return;
    final norm = Offset(d.localPosition.dx / size.width,
        d.localPosition.dy / size.height);
    final hit = _annotationAt(norm);
    if (hit != null) {
      ref.read(selectionProvider.notifier).openNote(hit.id);
      return;
    }
    // Tap on whitespace clears the selection (FEATURES 4.1.3).
    ref.read(selectionProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    // Preview only the selection belonging to this page.
    final selection = ref.watch(selectionProvider.select((s) => s.selection));
    final mine = selection != null && selection.page == widget.page
        ? selection
        : null;
    final color = Theme.of(context).colorScheme.primary;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      onPanDown: _onPanDown,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: CustomPaint(painter: _SelectionPreviewPainter(mine, color)),
    );
  }
}

/// Draws the live selection preview (FEATURES 6.1: semi-transparent primary
/// tint over each selected line).
class _SelectionPreviewPainter extends CustomPainter {
  _SelectionPreviewPainter(this.selection, this.color);

  final Selection? selection;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    if (sel == null || size.isEmpty) return;
    final paint = Paint()..color = color.withValues(alpha: 0.4);
    for (final r in sel.lineRects) {
      canvas.drawRect(
        Rect.fromLTWH(
          r.x * size.width,
          r.y * size.height,
          r.w * size.width,
          r.h * size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_SelectionPreviewPainter old) =>
      old.selection != selection || old.color != color;
}
