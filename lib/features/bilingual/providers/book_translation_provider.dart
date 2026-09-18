import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/reader/providers/image_decoder.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Bumped when a book's translated artifact appears / changes / is deleted,
/// so the pane's per-page image providers re-render.
final translationRevisionProvider = StateProvider<int>((ref) => 0);

/// State of the whole-book BabelDOC run for one book.
class BookTranslationState {
  const BookTranslationState({
    this.translation,
    this.running = false,
    this.phase = '',
    this.detail = '',
    this.error,
    this.loaded = false,
  });

  final BookTranslation? translation;
  final bool running;
  final String phase;
  final String detail;
  final String? error;

  /// Whether the initial disk probe has completed (the pane shows a spinner
  /// until then).
  final bool loaded;

  bool get hasArtifact => translation != null;

  BookTranslationState copyWith({
    BookTranslation? translation,
    bool? running,
    String? phase,
    String? detail,
    String? error,
    bool? loaded,
    bool clearError = false,
  }) =>
      BookTranslationState(
        translation: translation ?? this.translation,
        running: running ?? this.running,
        phase: phase ?? this.phase,
        detail: detail ?? this.detail,
        error: clearError ? null : (error ?? this.error),
        loaded: loaded ?? this.loaded,
      );
}

/// One book's translation: probes the artifact on build, drives the run
/// stream, exposes cancel / clear.
class BookTranslationController
    extends FamilyAsyncNotifier<BookTranslationState, int> {
  @override
  Future<BookTranslationState> build(int bookId) async {
    try {
      final res = await ref
          .read(translationRepositoryProvider)
          .getBookTranslation(bookId);
      return BookTranslationState(
        translation: res.translation,
        running: res.running,
        loaded: true,
      );
    } catch (e) {
      return BookTranslationState(error: e.toString(), loaded: true);
    }
  }

  /// Runs the whole-book translation, reflecting progress in [state].
  Future<void> translate() async {
    final repo = ref.read(translationRepositoryProvider);
    state = AsyncData(
      state.valueOrNull?.copyWith(
            running: true,
            phase: '启动引擎',
            detail: '',
            clearError: true,
          ) ??
          const BookTranslationState(running: true, phase: '启动引擎', loaded: true),
    );
    try {
      await for (final ev in repo.translateBook(arg)) {
        final current = state.valueOrNull ??
            const BookTranslationState(loaded: true);
        if (ev.error != null) {
          state = AsyncData(current.copyWith(
            running: false,
            phase: ev.phase,
            detail: ev.detail,
            error: ev.error,
          ));
          return;
        }
        state = AsyncData(current.copyWith(
          running: !ev.done,
          phase: ev.phase,
          detail: ev.detail,
          clearError: true,
        ));
      }
    } catch (e) {
      final current =
          state.valueOrNull ?? const BookTranslationState(loaded: true);
      state = AsyncData(current.copyWith(
        running: false,
        error: e.toString(),
      ));
      return;
    }
    await refresh();
  }

  Future<void> cancel() =>
      ref.read(translationRepositoryProvider).cancelBookTranslation();

  /// Deletes the produced PDFs and re-probes.
  Future<void> clear() async {
    await ref.read(translationRepositoryProvider).clearBookTranslation(arg);
    ref.read(translationRevisionProvider.notifier).state++;
    await refresh();
  }

  /// Re-reads the artifact from disk.
  Future<void> refresh() async {
    final repo = ref.read(translationRepositoryProvider);
    try {
      final res = await repo.getBookTranslation(arg);
      state = AsyncData(BookTranslationState(
        translation: res.translation,
        running: res.running,
        loaded: true,
      ));
      ref.read(translationRevisionProvider.notifier).state++;
    } catch (e) {
      state = AsyncData(BookTranslationState(error: e.toString(), loaded: true));
    }
  }
}

final bookTranslationProvider = AsyncNotifierProvider.family<
    BookTranslationController, BookTranslationState, int>(
  BookTranslationController.new,
);

/// One rendered page of the translated PDF (dpi 3.0 for crispness).
class TranslatedPageImage {
  const TranslatedPageImage({
    this.image,
    required this.hasTranslation,
    this.error,
  });

  final ui.Image? image;
  final bool hasTranslation;
  final String? error;
}

final translatedPageImageProvider = FutureProvider.family<TranslatedPageImage,
    ({int bookId, int page})>((ref, key) async {
  // Re-render when the artifact appears / changes.
  ref.watch(translationRevisionProvider);
  final repo = ref.read(translationRepositoryProvider);
  final bmp = await repo.renderTranslatedPage(
    bookId: key.bookId,
    page: key.page,
    dpiScale: 3.0,
  );
  if (bmp.error != null) {
    return TranslatedPageImage(
        hasTranslation: bmp.hasTranslation, error: bmp.error);
  }
  if (!bmp.hasTranslation || bmp.rgba.isEmpty) {
    return const TranslatedPageImage(hasTranslation: false);
  }
  final image = await decodeRgbaImage(bmp.width, bmp.height, bmp.rgba);
  return TranslatedPageImage(
    image: image,
    hasTranslation: true,
    error: image == null ? '译文页解码失败' : null,
  );
});
