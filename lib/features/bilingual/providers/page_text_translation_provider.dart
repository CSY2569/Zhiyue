import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/haptics.dart';
import 'package:rbwa/data/repositories/text_translation_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Per-page translation state for the text-level bilingual view.
class PageTextTranslationState {
  const PageTextTranslationState({
    this.translation,
    this.blocks,
    this.loading = false,
    this.error,
  });

  /// Cached or freshly produced translations.
  final PageTextTranslation? translation;

  /// Extracted source blocks (available before/without translation, e.g. when
  /// the LLM config is missing the UI can still show where text is).
  final PageTextBlocks? blocks;

  /// A translation request is in flight.
  final bool loading;

  /// Page-level failure (network / config / no text layer).
  final String? error;

  bool get hasResult => translation != null;
}

/// Translates the visible page and prefetches the next two.
///
/// One notifier per (book, page) pair; the reader watches only the visible
/// page. Prefetching is coordinated here (serial, max 2 pages ahead) so
/// flipping through a book does not fan out into parallel LLM calls.
///
/// autoDispose: a page's translation state is only needed while its column is
/// on screen. Without it every visited page kept its blocks (source +
/// translation text) alive for the whole process lifetime, so a long reading
/// session grew without bound.
class PageTextTranslationController extends AutoDisposeFamilyAsyncNotifier<
    PageTextTranslationState, ({int bookId, int page})> {
  static const _prefetchAhead = 2;

  /// Set once the provider is disposed (a flipped-away page). Riverpod 2.6's
  /// notifier ref has no `mounted`, so async continuations check this before
  /// writing state.
  bool _disposed = false;

  /// Prefetch is best-effort: skip it entirely while the app is backgrounded
  /// (mobile OSes throttle or kill background work, and the user is not
  /// reading).
  bool get _canPrefetch {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  Future<PageTextTranslationState> build(({int bookId, int page}) arg) async {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    final repo = ref.read(textTranslationRepositoryProvider);
    final targetLang = await _targetLang();
    try {
      final cached = await repo.getCached(arg.bookId, arg.page, targetLang);
      if (cached != null) {
        _schedulePrefetch(arg.bookId, arg.page);
        return PageTextTranslationState(
          translation: cached,
          blocks: _blocksFrom(cached),
        );
      }
      // No cache: extract the blocks now (local, no LLM) so the column can
      // show what would be translated before the user commits to a request.
      final PageTextBlocks blocks;
      try {
        blocks = await repo.getPageBlocks(arg.bookId, arg.page);
      } catch (e) {
        return PageTextTranslationState(error: e.toString());
      }
      return PageTextTranslationState(blocks: blocks, error: blocks.error);
    } catch (e) {
      return PageTextTranslationState(error: e.toString());
    }
  }

  /// Target language: the AI setting is the single source of truth
  /// (matches the desktop 划词翻译), defaulting to 中文.
  Future<String> _targetLang() async {
    final cfg = await ref.read(aiConfigProvider.future);
    final lang = cfg.translateTargetLang.trim();
    return lang.isEmpty ? '中文' : lang;
  }

  /// Extracted blocks only (no network) — used by the empty-state UI.
  Future<PageTextBlocks> loadBlocks() async {
    final repo = ref.read(textTranslationRepositoryProvider);
    final blocks = await repo.getPageBlocks(arg.bookId, arg.page);
    final current = state.valueOrNull;
    if (current != null && !_disposed) {
      state = AsyncData(
        PageTextTranslationState(
          translation: current.translation,
          blocks: blocks,
          loading: current.loading,
          error: current.error,
        ),
      );
    }
    return blocks;
  }

  /// Runs the translation for this page (cache first unless [force]).
  Future<void> translate({bool force = false}) async {
    final repo = ref.read(textTranslationRepositoryProvider);
    final current = state.valueOrNull ?? const PageTextTranslationState();
    state = AsyncData(
      PageTextTranslationState(
        translation: current.translation,
        blocks: current.blocks,
        loading: true,
      ),
    );
    final targetLang = await _targetLang();
    try {
      final result = await repo.translatePage(
        bookId: arg.bookId,
        page: arg.page,
        targetLang: targetLang,
        force: force,
      );
      if (_disposed) return;
      state = AsyncData(
        PageTextTranslationState(
          translation:
              result.blocks.isEmpty && result.error != null ? null : result,
          blocks: _blocksFrom(result),
          error: result.error,
        ),
      );
      if (result.error == null) {
        Haptics.success();
        _schedulePrefetch(arg.bookId, arg.page);
      } else {
        Haptics.warning();
      }
    } catch (e) {
      Haptics.warning();
      if (_disposed) return;
      state = AsyncData(
        PageTextTranslationState(
          translation: current.translation,
          blocks: current.blocks,
          error: e.toString(),
        ),
      );
    }
  }

  /// Cancels the in-flight request; the Rust side aborts at the next batch.
  Future<void> cancel() => ref.read(textTranslationRepositoryProvider).cancel();

  /// Deletes this book's cached text translations.
  Future<void> clearBook() async {
    await ref.read(textTranslationRepositoryProvider).clearBook(arg.bookId);
    ref.invalidateSelf();
  }

  /// Warms the next pages serially. `ref.read` of a sibling family instance
  /// would recurse into unbounded work, so this calls the repository
  /// directly for the cached probe and a single translate per page.
  void _schedulePrefetch(int bookId, int page) {
    _prefetch(bookId, page).ignore();
  }

  Future<void> _prefetch(int bookId, int page) async {
    final repo = ref.read(textTranslationRepositoryProvider);
    final targetLang = await _targetLang();
    for (var ahead = 1; ahead <= _prefetchAhead; ahead++) {
      // Re-check each iteration: the user may have backgrounded the app or
      // closed the pane mid-prefetch.
      if (_disposed || !_canPrefetch) return;
      final candidate = page + ahead;
      try {
        final cached = await repo.getCached(bookId, candidate, targetLang);
        if (cached != null) continue;
        await repo.translatePage(
          bookId: bookId,
          page: candidate,
          targetLang: targetLang,
        );
      } catch (_) {
        // Prefetch is best-effort; the visible page is what matters.
        return;
      }
    }
  }

  /// The FFI result carries geometry and source text, so the blocks view can
  /// be reconstructed without another extraction round-trip.
  PageTextBlocks? _blocksFrom(PageTextTranslation t) {
    if (t.blocks.isEmpty) return null;
    return PageTextBlocks(
      page: t.page,
      width: t.width,
      height: t.height,
      blocks: [
        for (final b in t.blocks)
          TextBlock(
            index: b.index,
            kind: b.kind,
            subType: b.subType,
            x: b.x,
            y: b.y,
            w: b.w,
            h: b.h,
            text: b.sourceText,
          ),
      ],
      error: null,
    );
  }
}

final pageTextTranslationProvider = AsyncNotifierProvider.autoDispose.family<
    PageTextTranslationController,
    PageTextTranslationState,
    ({int bookId, int page})>(PageTextTranslationController.new);
