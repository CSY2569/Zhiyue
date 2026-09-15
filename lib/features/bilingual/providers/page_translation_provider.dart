import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/progress.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Open/closed state of the bilingual-reading 对照 view.
///
/// No longer a side panel: when open, the READING AREA itself splits 50/50
/// into original (left) + translation (right), like the double-page mode.
/// [modeBefore] remembers the view mode the reader had before opening --
/// 对照 pairs one original page with its translation, so opening forces the
/// single-page view, and closing restores what the user had.
class TranslationPaneState {
  const TranslationPaneState({
    this.open = false,
    this.modeBefore,
  });

  final bool open;

  /// View mode to restore on close (null = the reader was already single-page).
  final ViewMode? modeBefore;
}

class TranslationPaneNotifier extends Notifier<TranslationPaneState> {
  @override
  TranslationPaneState build() => const TranslationPaneState();

  void toggle() {
    if (state.open) {
      close();
      return;
    }
    final viewer = ref.read(viewerProvider);
    // Remember a non-single mode so close() can restore it.
    final modeBefore =
        viewer.mode != ViewMode.single ? viewer.mode : state.modeBefore;
    if (viewer.mode != ViewMode.single) {
      ref.read(viewerProvider.notifier).setMode(ViewMode.single);
    }
    state = TranslationPaneState(open: true, modeBefore: modeBefore);
  }

  void close() {
    final restore = state.modeBefore;
    if (restore != null) {
      ref.read(viewerProvider.notifier).setMode(restore);
    }
    state = TranslationPaneState(open: false);
  }
}

final translationPaneProvider =
    NotifierProvider<TranslationPaneNotifier, TranslationPaneState>(
        TranslationPaneNotifier.new);

/// Load state of one visible page's translation. `loading` is true while a
/// manual / auto request is in flight; `translation` is the cached or freshly
/// produced result; `error` carries a human-readable failure.
class PageTranslationState {
  const PageTranslationState({
    this.translation,
    this.loading = false,
    this.error,
  });

  final PageTranslation? translation;
  final bool loading;
  final String? error;

  bool get hasTranslation => translation != null;

  PageTranslationState copyWith({
    PageTranslation? translation,
    bool? loading,
    String? error,
    bool clearError = false,
    bool clearTranslation = false,
  }) =>
      PageTranslationState(
        translation:
            clearTranslation ? null : (translation ?? this.translation),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
      );
}

/// One page's translation for a given (bookId, page) pair. The pane watches
/// the visible page(s); a jump immediately loads the new page's cached
/// translation (plan §5 跳页立即定位).
///
/// The target language is NOT part of the key: the Rust cache key derives it
/// from settings, so a language change is reflected by a re-read.
class PageTranslationNotifier
    extends FamilyAsyncNotifier<PageTranslationState, ({int bookId, int page})> {
  StreamSubscription<TranslationProgressEvent>? _sub;

  @override
  Future<PageTranslationState> build(({int bookId, int page}) arg) async {
    ref.onDispose(() => _sub?.cancel());
    // Try the cache first; no request is made until the user asks.
    final repo = ref.read(translationRepositoryProvider);
    try {
      final res = await repo.getPageTranslation(arg.bookId, arg.page);
      if (res.error != null) {
        return PageTranslationState(error: res.error);
      }
      return PageTranslationState(translation: res.translation);
    } catch (e) {
      return PageTranslationState(error: e.toString());
    }
  }

  /// Translates this page (manual button / queue call). [force] re-translates
  /// even when cached.
  Future<void> translate({bool force = false}) async {
    final repo = ref.read(translationRepositoryProvider);
    final current = state.valueOrNull ?? const PageTranslationState();
    state = AsyncData(current.copyWith(
      loading: true,
      clearError: true,
    ));
    final completer = Completer<void>();
    String? streamError;
    _sub?.cancel();
    _sub = repo
        .translatePage(bookId: arg.bookId, page: arg.page, force: force)
        .listen(
      (ev) {
        final s = state.valueOrNull ?? const PageTranslationState();
        if (ev.error != null) streamError = ev.error;
        state = AsyncData(s.copyWith(
          loading: !ev.finished,
          error: ev.error,
          clearError: ev.error == null,
        ));
        if (ev.finished && !completer.isCompleted) completer.complete();
      },
      onError: (Object e) {
        streamError = e.toString();
        final s = state.valueOrNull ?? const PageTranslationState();
        state = AsyncData(s.copyWith(loading: false, error: streamError));
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    await completer.future;
    // A page just finished translating: invalidate the rendered page images so
    // the pane switches from "尚未翻译" to the translation.
    ref.read(translationRevisionProvider.notifier).state++;
    // Re-read the cached row so the pane shows the paragraph list. A stream
    // failure must survive this refresh (there is no cached row to show).
    if (streamError != null) {
      final s = state.valueOrNull ?? const PageTranslationState();
      state = AsyncData(s.copyWith(loading: false, error: streamError));
      return;
    }
    try {
      final res = await repo.getPageTranslation(arg.bookId, arg.page);
      final s = state.valueOrNull ?? const PageTranslationState();
      state = AsyncData(s.copyWith(
        translation: res.translation,
        loading: false,
        error: res.error,
        clearError: res.error == null,
      ));
    } catch (e) {
      final s = state.valueOrNull ?? const PageTranslationState();
      state = AsyncData(s.copyWith(loading: false, error: e.toString()));
    }
  }
}

final pageTranslationProvider = AsyncNotifierProvider.family<
    PageTranslationNotifier,
    PageTranslationState,
    ({int bookId, int page})>(PageTranslationNotifier.new);
