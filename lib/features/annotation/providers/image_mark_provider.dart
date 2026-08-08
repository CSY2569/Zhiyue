import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';

// =============================================================================
// Tool + style state (FEATURES 5.1-5.4)
// =============================================================================

/// Which mark tool is armed; null = normal reading / selection mode.
/// [select] = move / scale / delete existing marks (FEATURES 5.1-5.3).
enum MarkTool { select, brush, shape, sticky, stamp }

/// Armed tool + its style (adjustable color / thickness, FEATURES 5.5).
class MarkToolState {
  const MarkToolState({
    this.tool,
    this.color = '#e53935',
    this.strokeWidth = 3,
    this.fill = false,
    this.fontSize = 14,
    this.shapeType = 'rect',
    this.stampFile,
  });

  final MarkTool? tool;
  final String color;
  final double strokeWidth;
  final bool fill;
  final double fontSize;

  /// Shape to draw with the shape tool: rect / ellipse / arrow (FEATURES 5.4).
  final String shapeType;

  /// Image file the stamp tool places (FEATURES 5.3); picked via the toolbar.
  final String? stampFile;

  MarkToolState copyWith({
    MarkTool? tool,
    bool clearTool = false,
    String? color,
    double? strokeWidth,
    bool? fill,
    double? fontSize,
    String? shapeType,
    String? stampFile,
  }) {
    return MarkToolState(
      tool: clearTool ? null : (tool ?? this.tool),
      color: color ?? this.color,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      fill: fill ?? this.fill,
      fontSize: fontSize ?? this.fontSize,
      shapeType: shapeType ?? this.shapeType,
      stampFile: stampFile ?? this.stampFile,
    );
  }
}

class MarkToolNotifier extends Notifier<MarkToolState> {
  @override
  MarkToolState build() => const MarkToolState();

  void setTool(MarkTool? tool) =>
      state = state.copyWith(tool: tool, clearTool: tool == null);
  void toggleTool(MarkTool tool) => state = state.tool == tool
      ? state.copyWith(clearTool: true)
      : state.copyWith(tool: tool);
  void setColor(String color) => state = state.copyWith(color: color);
  void setStrokeWidth(double w) => state = state.copyWith(strokeWidth: w);
  void toggleFill() => state = state.copyWith(fill: !state.fill);
  void setShapeType(String t) => state = state.copyWith(shapeType: t);
  void setStampFile(String? path) => state = state.copyWith(stampFile: path);
}

/// Mark tool state (armed tool + style).
final markToolProvider =
    NotifierProvider<MarkToolNotifier, MarkToolState>(MarkToolNotifier.new);

// =============================================================================
// Per-type visibility (FEATURES 5.5: filter show / hide by type)
// =============================================================================

class MarkVisibilityNotifier extends Notifier<Set<ImageMarkKind>> {
  @override
  Set<ImageMarkKind> build() => ImageMarkKind.values.toSet();

  void toggle(ImageMarkKind kind) {
    final next = Set<ImageMarkKind>.from(state);
    if (!next.remove(kind)) next.add(kind);
    state = next;
  }
}

/// Which mark kinds are visible in the layer panel (default: all).
final markVisibilityProvider =
    NotifierProvider<MarkVisibilityNotifier, Set<ImageMarkKind>>(
  MarkVisibilityNotifier.new,
);

// =============================================================================
// Marks of the open book + undo/redo (FEATURES 5.5 / 5.7)
// =============================================================================

/// Image-layer marks of the open book. Every mutation persists immediately
/// and pushes the inverse operation onto the undo stack (Ctrl+Z / Ctrl+
/// Shift+Z, 5.7); redo replays it.
class ImageMarkNotifier extends AsyncNotifier<List<ImageMark>> {
  /// Edit history (FEATURES 5.7): each entry carries both directions --
  /// [forward] applies the edit, [backward] reverts it. Undo pops the
  /// backward op (and pushes the flipped pair onto the redo stack); redo
  /// replays the forward one.
  final _undo =
      <({Future<void> Function() forward, Future<void> Function() backward})>[];
  final _redo =
      <({Future<void> Function() forward, Future<void> Function() backward})>[];

  ReaderRepository get _repo => ref.read(readerRepositoryProvider);

  @override
  Future<List<ImageMark>> build() {
    final bookId = ref.watch(viewerProvider.select((s) => s.book?.id));
    if (bookId == null) return Future.value(const []);
    return _repo
        .listImageAnnotations(bookId)
        .then((rows) => rows.map(ImageMark.fromRust).toList());
  }

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// In-memory geometry update during a drag (live preview, FEATURES 5.1-5.3:
  /// marks are selectable and movable). The caller persists via [update]
  /// when the gesture ends.
  void applyLocalDrag(int id, double x, double y, {double? w, double? h}) {
    final current = state.valueOrNull;
    if (current == null) return;
    state = AsyncValue.data([
      for (final m in current)
        if (m.id == id) m.copyWith(x: x, y: y, w: w, h: h) else m,
    ]);
  }

  /// Create a mark (FEATURES 5.1-5.4): persists, then reloads the list.
  Future<bool> create(ImageMark mark) async {
    final bookId = _bookId;
    if (bookId == null) return false;
    final res = await _repo.createImageAnnotation(
      bookId: bookId,
      page: mark.page,
      kind: imageMarkKindToRust(mark.kind),
      x: mark.x,
      y: mark.y,
      w: mark.w,
      h: mark.h,
      rotation: mark.rotation,
      payload: mark.payload,
      style: mark.style,
    );
    if (res.error != null || res.id < 0) return false;
    final id = res.id;
    _pushEdit(
      backward: () async => _repo.deleteImageAnnotation(id),
      forward: () async => _repo.createImageAnnotation(
        bookId: bookId,
        page: mark.page,
        kind: imageMarkKindToRust(mark.kind),
        x: mark.x,
        y: mark.y,
        w: mark.w,
        h: mark.h,
        rotation: mark.rotation,
        payload: mark.payload,
        style: mark.style,
      ),
    );
    ref.invalidateSelf();
    return true;
  }

  /// Update a mark's geometry / payload / style (selectable, movable,
  /// editable, FEATURES 5.1-5.5). [before] is the pre-edit snapshot used by
  /// undo; the layer captures it when the drag starts.
  Future<bool> updateMark(ImageMark mark, {ImageMark? before}) async {
    final ok = await _repo.updateImageAnnotation(
      annotationId: mark.id,
      x: mark.x,
      y: mark.y,
      w: mark.w,
      h: mark.h,
      rotation: mark.rotation,
      payload: mark.payload,
      style: mark.style,
    );
    if (ok <= 0) return false;
    final saved = before;
    _pushEdit(
      backward: () async {
        if (saved == null) return;
        await _repo.updateImageAnnotation(
          annotationId: mark.id,
          x: saved.x,
          y: saved.y,
          w: saved.w,
          h: saved.h,
          rotation: saved.rotation,
          payload: saved.payload,
          style: saved.style,
        );
      },
      forward: () async => _repo.updateImageAnnotation(
        annotationId: mark.id,
        x: mark.x,
        y: mark.y,
        w: mark.w,
        h: mark.h,
        rotation: mark.rotation,
        payload: mark.payload,
        style: mark.style,
      ),
    );
    ref.invalidateSelf();
    return true;
  }

  /// Delete one mark (FEATURES 5.5).
  Future<bool> delete(int id) async {
    final before = _snapshot;
    final mark = before.cast<ImageMark?>().firstWhere(
        (m) => m?.id == id,
        orElse: () => null);
    final ok = await _repo.deleteImageAnnotation(id) > 0;
    if (!ok) return false;
    if (mark != null) {
      final saved = mark;
      _pushEdit(
        backward: () async => _repo.createImageAnnotation(
          bookId: _bookId ?? -1,
          page: saved.page,
          kind: imageMarkKindToRust(saved.kind),
          x: saved.x,
          y: saved.y,
          w: saved.w,
          h: saved.h,
          rotation: saved.rotation,
          payload: saved.payload,
          style: saved.style,
        ),
        forward: () async => _repo.deleteImageAnnotation(id),
      );
    }
    ref.invalidateSelf();
    return true;
  }

  /// Clear every mark of the book (FEATURES 5.5: 整体清空).
  Future<void> clearAll() async {
    for (final m in _snapshot) {
      await delete(m.id);
    }
  }

  Future<void> undo() async {
    if (_undo.isEmpty) return;
    final op = _undo.removeLast();
    await op.backward();
    // The entry moves between stacks unchanged: undo runs [backward],
    // redo runs [forward].
    _redo.add(op);
    ref.invalidateSelf();
  }

  Future<void> redo() async {
    if (_redo.isEmpty) return;
    final op = _redo.removeLast();
    await op.forward();
    _undo.add(op);
    ref.invalidateSelf();
  }

  void _pushEdit({
    required Future<void> Function() forward,
    required Future<void> Function() backward,
  }) {
    _undo.add((forward: forward, backward: backward));
    _redo.clear(); // new edits invalidate the redo branch (5.7)
  }

  int? get _bookId => ref.read(viewerProvider).book?.id;

  List<ImageMark> get _snapshot => state.valueOrNull ?? const [];
}

/// Image-layer marks of the open book (auto-reloads on book switch).
final imageMarkProvider =
    AsyncNotifierProvider<ImageMarkNotifier, List<ImageMark>>(
  ImageMarkNotifier.new,
);
