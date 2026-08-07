import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Loads the open book's annotations and exposes CRUD + export (FEATURES
/// 4.3.5: marks persist and reload automatically when the book opens).
///
/// Tracks the book through the viewer state, so switching books reloads the
/// list automatically. Mutations invalidate the state to refetch from SQLite
/// (a local query, so the UI updates instantly -- FEATURES 4.4.2).
class AnnotationNotifier extends AsyncNotifier<List<TextAnnotation>> {
  @override
  Future<List<TextAnnotation>> build() async {
    final bookId = ref.watch(viewerProvider.select((s) => s.book?.id));
    if (bookId == null) return const [];
    return ref.watch(readerRepositoryProvider).listAnnotations(bookId);
  }

  ReaderRepository get _repo => ref.read(readerRepositoryProvider);
  int? get _bookId => ref.read(viewerProvider).book?.id;

  /// Create a mark or note from a selection (FEATURES 4.3 / 4.4.1).
  /// [rects] holds one normalized rect per selected line.
  Future<bool> create({
    required TextAnnotationKind kind,
    required int page, // 0-indexed
    String? text,
    String? content,
    required List<NormRect> rects,
    String? color,
  }) async {
    final bookId = _bookId;
    if (bookId == null) return false;
    final result = await _repo.createAnnotation(
      bookId: bookId,
      page: page,
      kind: kind,
      text: text,
      content: content,
      rects: rects,
      color: color,
    );
    if (result.error != null || result.id < 0) return false;
    ref.invalidateSelf();
    return true;
  }

  /// Save a note's body (FEATURES 4.4.2).
  Future<bool> updateContent(int id, String? content) async {
    final ok = await _repo.updateAnnotationContent(id, content) > 0;
    if (ok) ref.invalidateSelf();
    return ok;
  }

  /// Delete an annotation (FEATURES 4.4.2 / 4.5.1).
  Future<bool> delete(int id) async {
    final ok = await _repo.deleteAnnotation(id) > 0;
    if (ok) ref.invalidateSelf();
    return ok;
  }

  /// Markdown export for the open book (FEATURES 4.5.2), or null on error.
  Future<String?> exportMarkdown() async {
    final bookId = _bookId;
    if (bookId == null) return null;
    final r = await _repo.exportAnnotationsMarkdown(bookId);
    return r.error == null ? r.content : null;
  }

  /// JSON export for the open book (FEATURES 4.5.3), or null on error.
  Future<String?> exportJson() async {
    final bookId = _bookId;
    if (bookId == null) return null;
    final r = await _repo.exportAnnotationsJson(bookId);
    return r.error == null ? r.content : null;
  }
}

/// Annotations of the currently open book, empty while no book is open.
final annotationProvider =
    AsyncNotifierProvider<AnnotationNotifier, List<TextAnnotation>>(
  AnnotationNotifier.new,
);
