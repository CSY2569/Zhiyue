import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/haptics.dart';
import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/widgets/text_input_dialog.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/annotation/providers/low_confidence_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/bilingual/providers/translated_char_box_cache.dart';
import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/features/reader/providers/ocr_helpers.dart';
import 'package:rbwa/features/reader/providers/reader_tap_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'package:rbwa/src/rust/models/annotation.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine;
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// Pointer layer on top of one page: drag to select characters (FEATURES
/// 4.1), tap a mark to open its note (FEATURES 4.4.2), tap whitespace to
/// clear (FEATURES 4.1.3). Also paints the live selection preview.
///
/// Hit-testing runs against the page's CharBoxes in *normalized* coordinates
/// (scaled from the layer's own size), so it stays correct at any zoom. The
/// char boxes are preloaded on init / page change so the first drag works
/// immediately.
///
/// Two paths:
/// - **Native PDF** (pdfium per-glyph boxes): one char per box, hit-tested by
///   [charIndexAt] (horizontal proximity). High precision.
/// - **OCR** (one box per recognized line): hit-tested by [lineIndexAt] +
///   [LineLayout], which uses [TextPainter.getPositionForOffset] for
///   kerning-aware in-line character positioning. This handles mixed CJK +
///   Latin + symbols accurately without synthesizing fake per-char boxes.
class SelectionLayer extends ConsumerStatefulWidget {
  const SelectionLayer({
    super.key,
    required this.bookId,
    required this.page, // 0-indexed
    required this.annotations, // annotations of this page
    this.translated = false,
    this.longPressSelect = false,
  });

  final int bookId;
  final int page;
  final List<TextAnnotation> annotations;

  /// Selecting on the TRANSLATED pane (对照 view): char boxes come from the
  /// translated-PDF cache and annotations / OCR markers stay off. The page
  /// index is the book's absolute page (both panes are 1:1).
  final bool translated;

  /// Touch layout: start selecting with a LONG PRESS instead of a plain drag,
  /// so a single-finger drag still scrolls the page. Desktop keeps
  /// drag-to-select (there is no touch scrolling to compete with).
  final bool longPressSelect;

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
  // Line layouts for OCR (line-level) boxes; null for native PDF (per-char).
  List<LineLayout>? _lineLayouts;

  /// Word range selected by the long press that started the gesture. While
  /// the finger moves, the selection spans from this whole word to the word
  /// under the pointer, so the anchor word never shrinks to a single
  /// character mid-drag.
  int? _wordLo;
  int? _wordHi;

  /// Current committed endpoints, mirrored here so a handle drag knows the
  /// fixed end. Encoded positions for line-level (OCR) boxes.
  int? _selLo;
  int? _selHi;

  @override
  void initState() {
    super.initState();
    _preloadBoxes();
  }

  @override
  void didUpdateWidget(SelectionLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.bookId != widget.bookId) {
      _disposeLineLayouts();
      _preloadBoxes();
    }
  }

  @override
  void dispose() {
    _disposeLineLayouts();
    super.dispose();
  }

  void _disposeLineLayouts() {
    final layouts = _lineLayouts;
    _lineLayouts = null;
    if (layouts != null) {
      for (final l in layouts) {
        l.dispose();
      }
    }
  }

  /// Kick off the char-box load (the selection's data). The provider update
  /// rebuilds this layer once the boxes arrive. Runs post-frame so it never
  /// mutates providers during build.
  void _preloadBoxes() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.translated) {
        ref
            .read(translatedCharBoxCacheProvider.notifier)
            .getOrFetch(widget.bookId, widget.page);
      } else {
        ref
            .read(charBoxCacheProvider.notifier)
            .getOrFetch(widget.bookId, widget.page);
      }
    });
  }

  List<CharBox>? get _boxes => widget.translated
      ? ref.watch(translatedCharBoxCacheProvider.select((m) => m[widget.page]))
      : ref.watch(charBoxCacheProvider.select((m) => m[widget.page]));

  /// Build line layouts for OCR (line-level) boxes. Called after boxes arrive
  /// when [isLineLevelBoxes] is true. The page width in pixels is the layer's
  /// render width (so TextPainter lays out at display resolution).
  void _ensureLineLayouts(List<CharBox> boxes) {
    if (_lineLayouts != null) return; // already built
    if (!isLineLevelBoxes(boxes)) return; // native PDF: per-char, no layouts
    final render = context.findRenderObject() as RenderBox?;
    final pageWidthPx = render?.size.width ?? 800.0;
    _lineLayouts = [
      for (final b in boxes)
        if (b.char.length > 1) LineLayout(b, pageWidthPx),
    ];
  }

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
    final layouts = _lineLayouts;
    final source = widget.translated
        ? SelectionSource.translated
        : SelectionSource.original;
    if (layouts != null) {
      final sel = Selection(
        page: widget.page,
        anchorIndex: anchor,
        currentIndex: idx,
        text: selectionTextFromLines(boxes, anchor, idx),
        lineRects: selectionRectsFromLines(boxes, layouts, anchor, idx),
        source: source,
      );
      _selLo = math.min(anchor, idx);
      _selHi = math.max(anchor, idx);
      ref.read(selectionProvider.notifier).updateSelection(sel);
    } else {
      final sel = Selection(
        page: widget.page,
        anchorIndex: anchor,
        currentIndex: idx,
        text: selectionText(boxes, anchor, idx),
        lineRects: selectionRects(boxes, anchor, idx),
        source: source,
      );
      _selLo = math.min(anchor, idx);
      _selHi = math.max(anchor, idx);
      ref.read(selectionProvider.notifier).updateSelection(sel);
    }
  }

  /// Whether [sel] was made on THIS layer: same page AND same pane (the
  /// original page and the translated pane share page indices, so the page
  /// alone would let both panes paint one another's selection).
  bool _owns(Selection? sel) {
    if (sel == null || sel.page != widget.page) return false;
    final expected = widget.translated
        ? SelectionSource.translated
        : SelectionSource.original;
    return sel.source == expected;
  }

  void _onPanDown(DragDownDetails d) => _dragDownPos = d.localPosition;

  void _onLongPressStart(LongPressStartDetails d) {
    _dragDownPos = d.localPosition;
    _beginSelection(d.localPosition, expandWord: true);
    if (_wordLo != null) Haptics.select();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    _updateSelection(d.localPosition);
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    _endSelection();
  }

  void _onPanStart(DragStartDetails d) => _beginSelection(d.localPosition);

  void _onPanUpdate(DragUpdateDetails d) => _updateSelection(d.localPosition);

  void _onPanEnd(DragEndDetails d) => _endSelection();

  void _beginSelection(Offset position, {bool expandWord = false}) {
    final boxes = _boxes;
    if (boxes == null) {
      // Char boxes not loaded yet -- kick off the fetch; the provider update
      // rebuilds this layer and the next drag works.
      _preloadBoxes();
      return;
    }
    if (boxes.isEmpty) return; // no text layer on this page
    _ensureLineLayouts(boxes);
    final norm = _toNorm(_dragDownPos ?? position);
    final idx = _lineLayouts != null
        ? lineIndexAt(boxes, _lineLayouts!, norm)
        : charIndexAt(boxes, norm);
    if (idx < 0) {
      // Drag began in whitespace: nothing to select.
      _wordLo = null;
      _wordHi = null;
      ref.read(selectionProvider.notifier).clear();
      return;
    }
    if (!expandWord) {
      _wordLo = null;
      _wordHi = null;
      _dragAnchor = idx;
      _setSelection(idx);
      return;
    }
    // Touch long-press: select the whole word under the finger.
    final (lo, hi) = _lineLayouts != null
        ? wordRangeAtEncoded(boxes, idx)
        : wordRangeAt(boxes, idx);
    _wordLo = lo;
    _wordHi = hi;
    _dragAnchor = lo;
    _setSelection(hi);
  }

  void _updateSelection(Offset position) {
    final boxes = _boxes;
    if (boxes == null || _dragAnchor == null) return;
    final norm = _toNorm(position);
    final idx = _lineLayouts != null
        ? lineIndexAt(boxes, _lineLayouts!, norm)
        : charIndexAt(boxes, norm);
    if (idx < 0) return; // pointer left the text grid; keep last range

    final wordLo = _wordLo;
    final wordHi = _wordHi;
    if (wordLo == null || wordHi == null) {
      _setSelection(idx);
      return;
    }
    // Word-drag: include the entire word under the pointer, keeping the
    // anchor word fully selected.
    final (plo, phi) = _lineLayouts != null
        ? wordRangeAtEncoded(boxes, idx)
        : wordRangeAt(boxes, idx);
    final lo = math.min(wordLo, plo);
    final hi = math.max(wordHi, phi);
    _dragAnchor = lo;
    _setSelection(hi);
  }

  void _endSelection() {
    _dragDownPos = null;
    if (_dragAnchor == null) return;
    _dragAnchor = null;
    // Anchor the floating toolbar above the selection's first line, in
    // global coordinates (the toolbar lives in an Overlay).
    final sel = ref.read(selectionProvider).selection;
    if (!_owns(sel) || sel!.lineRects.isEmpty) {
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
    final norm = _toNorm(d.localPosition);
    final hit = _annotationAt(norm);
    if (hit != null) {
      ref.read(selectionProvider.notifier).openNote(hit.id);
      return;
    }
    // Tap a low-confidence OCR marker -> edit that line's text (7.1.7).
    // Meaningless on the translated pane (its text is not OCR output).
    final low = widget.translated ? null : _lowConfidenceAt(norm);
    if (low != null) {
      _editOcrLine(low.index, low.line);
      return;
    }
    // Tap on whitespace clears the selection (FEATURES 4.1.3) and reports
    // the tap so the reader can page (edges) or toggle its chrome (middle).
    ref.read(selectionProvider.notifier).clear();
    if (PlatformCapabilities.current().isMobile && !widget.translated) {
      ref.read(readerTapProvider.notifier).report(norm.dx);
    }
  }

  /// The low-confidence line whose normalized rect contains [norm], or null.
  /// The cache is shared with the marking layer via
  /// [lowConfidenceCacheProvider]; a miss kicks off the async fetch (the
  /// markers appear once it lands).
  LowConfidenceLine? _lowConfidenceAt(Offset norm) {
    final cache = ref.read(lowConfidenceCacheProvider);
    var low = cache[widget.page];
    if (low == null) {
      ref
          .read(lowConfidenceCacheProvider.notifier)
          .getOrFetch(widget.bookId, widget.page);
      return null;
    }
    for (final entry in low) {
      final l = entry.line;
      if (norm.dx >= l.x &&
          norm.dx <= l.x + l.w &&
          norm.dy >= l.y &&
          norm.dy <= l.y + l.h) {
        return entry;
      }
    }
    return null;
  }

  /// Edit dialog for one OCR line (7.1.7): correct the text, persist via the
  /// Rust core (re-indexes for search), refresh the text layer + scan count.
  Future<void> _editOcrLine(int index, OcrLine line) async {
    final newText = await showTextInputDialog(
      context,
      title: '修正识别文本',
      initial: line.text,
      hint: '输入修正后的文字',
      confirmLabel: '保存',
      maxLines: 3,
    );
    if (newText == null || newText.trim().isEmpty || newText == line.text) {
      return;
    }
    final mode = await configuredOcrMode(ref.read(aiConfigProvider.future));
    final updated = await ref.read(readerRepositoryProvider).updatePageOcrLines(
          widget.bookId,
          widget.page,
          mode,
          [(lineIndex: index, text: newText.trim())],
        );
    if (!mounted || updated == null) return;
    // Refresh the invisible text layer and the low-confidence markers.
    ref.invalidate(charBoxCacheProvider);
    ref.invalidate(lowConfidenceCacheProvider);
    // Re-derive the low-confidence count for the scan overlay.
    final count = updated.lines
        .where((l) => l.confidence < kLowConfidenceThreshold)
        .length;
    ref.read(scanStateProvider.notifier).refreshLowConfidence(widget.page, count);
  }

  /// The two handle positions (normalized page space), from the first /
  /// last selected line rect. Start handle sits on the left edge of the first
  /// line, end handle on the right edge of the last line.
  ({Offset start, Offset end})? _handlePositions(Selection sel) {
    if (sel.lineRects.isEmpty) return null;
    final first = sel.lineRects.first;
    final last = sel.lineRects.last;
    return (
      start: Offset(first.x, first.y + first.h),
      end: Offset(last.x + last.w, last.y + last.h),
    );
  }

  /// Updates the selection while one handle is dragged. The opposite end
  /// stays fixed; the dragged end snaps to the word under the pointer.
  void _dragHandle(_SelHandle handle, Offset local) {
    final boxes = _boxes;
    if (boxes == null) return;
    final norm = _toNorm(local);
    final idx = _lineLayouts != null
        ? lineIndexAt(boxes, _lineLayouts!, norm)
        : charIndexAt(boxes, norm);
    if (idx < 0) return;

    final (plo, phi) = _lineLayouts != null
        ? wordRangeAtEncoded(boxes, idx)
        : wordRangeAt(boxes, idx);
    final lo = _selLo;
    final hi = _selHi;
    if (lo == null || hi == null) return;

    // Dragging the START handle moves the low end; dragging the END handle
    // moves the high end. The fixed end becomes the drag anchor so the rects
    // / text are always built in document order.
    if (handle == _SelHandle.start) {
      _dragAnchor = hi;
      _setSelection(math.min(plo, hi));
    } else {
      _dragAnchor = lo;
      _setSelection(math.max(phi, lo));
    }
  }

  void _onHandleDragStart(_SelHandle which) {
    final sel = ref.read(selectionProvider).selection;
    if (sel != null && _owns(sel)) {
      _selLo = math.min(sel.anchorIndex, sel.currentIndex);
      _selHi = math.max(sel.anchorIndex, sel.currentIndex);
    }
    Haptics.tap();
  }

  void _onHandleDragEnd() {
    final sel = ref.read(selectionProvider).selection;
    if (sel == null || !_owns(sel)) return;
    // Re-anchor the toolbar to the updated selection.
    final render = context.findRenderObject() as RenderBox?;
    if (render == null || render.size.isEmpty) return;
    final origin = render.localToGlobal(Offset.zero);
    final size = render.size;
    if (sel.lineRects.isEmpty) return;
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

  @override
  Widget build(BuildContext context) {
    // Preview only the selection belonging to this page.
    final selection = ref.watch(selectionProvider.select((s) => s.selection));
    // Ensure line layouts are built when boxes arrive (post-frame, because
    // findRenderObject needs the layer to be laid out).
    final boxes = _boxes;
    if (boxes != null && boxes.isNotEmpty && _lineLayouts == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureLineLayouts(boxes);
      });
    }
    final mine = _owns(selection) ? selection : null;
    final color = Theme.of(context).colorScheme.primary;

    final handles = widget.longPressSelect && mine != null
        ? _handlePositions(mine)
        : null;

    final painter = CustomPaint(
      painter: _SelectionPreviewPainter(mine, color),
    );
    if (widget.longPressSelect) {
      // Touch: long-press to anchor the selection, drag to extend, release
      // to show the toolbar. Ordinary drags stay with the scroll view.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: _onTapUp,
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        onLongPressStart: _onLongPressStart,
        onLongPressMoveUpdate: _onLongPressMoveUpdate,
        onLongPressEnd: _onLongPressEnd,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: painter),
            if (handles != null) ...[
              _handleWidget(handles.start, _SelHandle.start),
              _handleWidget(handles.end, _SelHandle.end),
            ],
          ],
        ),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: _onTapUp,
      onPanDown: _onPanDown,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      child: painter,
    );
  }

  /// A selection handle: a 32dp hit target (Material's minimum for precise
  /// drags) around an 12dp dot. Only the handle itself consumes drags, so the
  /// rest of the page still scrolls.
  Widget _handleWidget(Offset norm, _SelHandle which) {
    final render = context.findRenderObject() as RenderBox?;
    final size = render?.size ?? Size.zero;
    const hit = 40.0;
    return Positioned(
      left: norm.dx * size.width - hit / 2,
      top: norm.dy * size.height - hit / 2,
      width: hit,
      height: hit,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // `d.globalPosition` is in screen space; the layer converts it to its
        // own local space. Using the handle's localPosition here would be
        // relative to the 40dp handle box, not the page.
        onPanStart: (_) => _onHandleDragStart(which),
        onPanUpdate: (d) => _dragHandle(
          which,
          (context.findRenderObject() as RenderBox?)
                  ?.globalToLocal(d.globalPosition) ??
              d.globalPosition,
        ),
        onPanEnd: (_) => _onHandleDragEnd(),
        onPanCancel: _onHandleDragEnd,
        child: Center(
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
              border: Border.all(
                color: Theme.of(context).colorScheme.surface,
                width: 2,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Position of the last double tap (TapDown gives the coordinates that
  /// `onDoubleTap` itself does not).
  Offset? _doubleTapPos;

  void _onDoubleTapDown(TapDownDetails d) => _doubleTapPos = d.localPosition;

  /// Double-tap on text selects the word under the finger; on blank space it
  /// toggles zoom, preserving the reader's previous double-tap behavior.
  void _onDoubleTap() {
    final pos = _doubleTapPos;
    _doubleTapPos = null;
    if (pos == null) return;
    final boxes = _boxes;
    if (boxes != null && boxes.isNotEmpty) {
      _ensureLineLayouts(boxes);
      final norm = _toNorm(pos);
      final idx = _lineLayouts != null
          ? lineIndexAt(boxes, _lineLayouts!, norm)
          : charIndexAt(boxes, norm);
      if (idx >= 0) {
        final (lo, hi) = _lineLayouts != null
            ? wordRangeAtEncoded(boxes, idx)
            : wordRangeAt(boxes, idx);
        _wordLo = lo;
        _wordHi = hi;
        _dragAnchor = lo;
        _setSelection(hi);
        Haptics.select();
        _endSelection();
        return;
      }
    }
    // Blank area: same zoom toggle as the reader's double tap.
    final viewer = ref.read(viewerProvider);
    ref.read(viewerProvider.notifier).setZoom(viewer.zoom > 1.6 ? 1.2 : 2.0);
  }
}

/// Which end of the selection a drag is moving.
enum _SelHandle { start, end }

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
