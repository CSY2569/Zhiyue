import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Open/closed state of the bilingual-reading translation pane (对照阅读).
///
/// Kept separate from the panel layout (which owns the width) so the toolbar
/// button and the reader Row can watch a tiny slice. Also tracks the order in
/// which panels were opened: when the left sidebar, translation pane and AI
/// panel squeeze the reading area, the LATER-opened panel is clamped first
/// (plan §1 v4.2 后开启者优先).
class TranslationPaneState {
  const TranslationPaneState({
    this.open = false,
    this.openSeq = 0,
  });

  final bool open;

  /// Monotonic counter bumped each time the pane opens; higher = opened later.
  final int openSeq;

  TranslationPaneState copyWith({bool? open, int? openSeq}) =>
      TranslationPaneState(
        open: open ?? this.open,
        openSeq: openSeq ?? this.openSeq,
      );
}

class TranslationPaneNotifier extends Notifier<TranslationPaneState> {
  @override
  TranslationPaneState build() => const TranslationPaneState();

  void toggle() {
    final next = !state.open;
    state = state.copyWith(
      open: next,
      openSeq: next ? state.openSeq + 1 : state.openSeq,
    );
  }

  void close() => state = state.copyWith(open: false);
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
    this.progressDone = 0,
    this.progressTotal = 0,
  });

  final PageTranslation? translation;
  final bool loading;
  final String? error;
  final int progressDone;
  final int progressTotal;

  bool get hasTranslation => translation != null;

  PageTranslationState copyWith({
    PageTranslation? translation,
    bool? loading,
    String? error,
    int? progressDone,
    int? progressTotal,
    bool clearError = false,
    bool clearTranslation = false,
  }) =>
      PageTranslationState(
        translation:
            clearTranslation ? null : (translation ?? this.translation),
        loading: loading ?? this.loading,
        error: clearError ? null : (error ?? this.error),
        progressDone: progressDone ?? this.progressDone,
        progressTotal: progressTotal ?? this.progressTotal,
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
      progressDone: 0,
      progressTotal: 0,
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
          progressDone: ev.doneParagraphs,
          progressTotal: ev.totalParagraphs,
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
