import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Whole-book translation queue state (plan §9: orchestration is Dart-side).
class TranslationQueueState {
  const TranslationQueueState({
    this.bookId,
    this.running = false,
    this.paused = false,
    this.totalPages = 0,
    this.donePages = 0,
    this.error,
    this.currentPage,
  });

  final int? bookId;
  final bool running;

  /// Paused by the 切书暂停·回来续传 behaviour (plan §10).
  final bool paused;
  final int totalPages;
  final int donePages;

  /// The page a running task is currently on (pane header hint).
  final int? currentPage;
  final String? error;

  double get progress =>
      totalPages == 0 ? 0 : (donePages / totalPages).clamp(0.0, 1.0);

  /// Rough remaining-time estimate: ~4 s/page (plan §7: DeepL 1-2 s, LLM
  /// 3-10 s per page; the pane shows the value as approximate).
  Duration? get estimatedRemaining {
    if (!running || totalPages == 0) return null;
    final remaining = (totalPages - donePages).clamp(0, totalPages);
    return Duration(seconds: remaining * 4);
  }

  TranslationQueueState copyWith({
    int? bookId,
    bool? running,
    bool? paused,
    int? totalPages,
    int? donePages,
    int? currentPage,
    String? error,
    bool clearBook = false,
    bool clearError = false,
    bool clearPage = false,
  }) =>
      TranslationQueueState(
        bookId: clearBook ? null : (bookId ?? this.bookId),
        running: running ?? this.running,
        paused: paused ?? this.paused,
        totalPages: totalPages ?? this.totalPages,
        donePages: donePages ?? this.donePages,
        currentPage: clearPage ? null : (currentPage ?? this.currentPage),
        error: clearError ? null : (error ?? this.error),
      );
}

/// Serialises per-page atomic calls into a whole-book run, with a
/// configurable concurrency, cache skipping, cancellation and resume
/// (plan §9/§10).
///
/// Only ONE whole-book task runs at a time; switching books applies the
/// configured background behaviour.
class TranslationQueueNotifier extends Notifier<TranslationQueueState> {
  int _generation = 0;
  final Set<int> _inflight = {};
  final List<int> _pending = [];
  bool _draining = false;
  bool _disposed = false;

  @override
  TranslationQueueState build() {
    ref.onDispose(() => _disposed = true);
    return const TranslationQueueState();
  }

  /// Reads a provider only while this notifier's container is alive; returns
  /// null after disposal so in-flight async loops stop cleanly.
  T? _safeRead<T>(T Function() read) {
    if (_disposed) return null;
    try {
      return read();
    } catch (_) {
      return null;
    }
  }

  int get _concurrency {
    final c = ref.read(translationConfigProvider).valueOrNull?.concurrency ?? 2;
    return c.clamp(1, 8);
  }

  /// Starts (or resumes) the whole-book translation for [bookId] over
  /// `1..totalPages`. Already-cached pages are skipped (the pipeline returns
  /// them; `translated_pages` seeds [donePages]).
  Future<void> startBook({required int bookId, required int totalPages}) async {
    final repo = ref.read(translationRepositoryProvider);
    if (state.running) {
      // A different book while one is running: apply the background rule.
      final behavior = ref
              .read(translationConfigProvider)
              .valueOrNull
              ?.backgroundBehavior ??
          TranslationBackgroundBehavior.ask;
      if (behavior == TranslationBackgroundBehavior.cancel) {
        await cancel();
      } else if (behavior == TranslationBackgroundBehavior.pauseResume) {
        await pause();
      }
      // `continue` falls through: both books share this single queue, so the
      // new request is appended after the current run (simplest safe policy).
    }

    _generation++;
    final gen = _generation;
    _pending
      ..clear()
      ..addAll(List.generate(totalPages, (i) => i + 1));
    _inflight.clear();

    // Seed progress from the cache so resume doesn't recount.
    int alreadyDone = 0;
    try {
      final overview = await repo.getTranslationOverview(bookId);
      alreadyDone = overview.translatedPages;
    } catch (_) {}
    // Remove cached pages from the work list (translate_page is cheap on a
    // hit, but skipping avoids N no-op streams).
    try {
      final done = <int>{};
      for (final p in _pending) {
        final res = await repo.getPageTranslation(bookId, p);
        if (res.translation != null) done.add(p);
      }
      _pending.removeWhere(done.contains);
    } catch (_) {}

    await repo.startBookTranslation(bookId);
    // A cancel() during the seeding awaits above bumped the generation:
    // honour it instead of resurrecting the run.
    if (gen != _generation) return;
    state = TranslationQueueState(
      bookId: bookId,
      running: true,
      totalPages: totalPages,
      donePages: alreadyDone.clamp(0, totalPages),
    );
    await _drain(bookId, gen);
  }

  /// Cancels the run and clears the in-flight registration (plan §9). Pages
  /// already translated stay cached.
  Future<void> cancel() async {
    final bookId = state.bookId;
    _generation++;
    _pending.clear();
    _inflight.clear();
    _draining = false;
    if (bookId != null) {
      await ref.read(translationRepositoryProvider).cancelTranslation(bookId);
    }
    state = state.copyWith(
      running: false,
      paused: false,
      clearBook: true,
      clearPage: true,
    );
  }

  /// Pauses the run (切书暂停·回来续传): the current page finishes, no new
  /// page is issued; [resume] continues.
  Future<void> pause() async {
    state = state.copyWith(paused: true, running: false);
  }

  /// Resumes a paused / interrupted run (plan §9 自动续传).
  Future<void> resume() async {
    final bookId = state.bookId;
    if (bookId == null || state.totalPages == 0) return;
    if (state.paused) {
      state = state.copyWith(paused: false, running: true);
      await _drain(bookId, _generation);
    }
  }

  /// Called when the reader's visible pages change (plan §10 随进度): with
  /// `with_progress` mode, enqueues the visible pages plus the next two,
  /// skipping cached ones.
  ///
  /// Awaits the config future: the config loads asynchronously from Rust, and
  /// a synchronous `valueOrNull` read at book-open time was usually still null,
  /// which made this return early and NEVER retry -- so 随进度 mode silently
  /// never called the API on opening a book (the reported "没有入口").
  Future<void> onVisiblePages(int bookId, List<int> visible) async {
    final TranslationConfig tc;
    try {
      tc = await ref.read(translationConfigProvider.future);
    } catch (_) {
      return;
    }
    if (tc.mode != TranslationMode.withProgress) return;
    if (state.bookId != null && state.bookId != bookId) return;
    final repo = ref.read(translationRepositoryProvider);
    final targets = <int>{};
    for (final p in visible) {
      for (var i = 0; i < 3; i++) {
        targets.add(p + i);
      }
    }
    for (final p in targets) {
      if (p < 1) continue;
      if (_inflight.contains(p) || _pending.contains(p)) continue;
      final res = await repo.getPageTranslation(bookId, p);
      if (res.translation != null) continue;
      _pending.add(p);
    }
    if (_pending.isEmpty) return;
    await repo.startBookTranslation(bookId);
    if (state.bookId == null) {
      state = TranslationQueueState(bookId: bookId, running: true);
    }
    await _drain(bookId, _generation);
  }

  /// Resume check after opening a book (plan §9): if the overview shows an
  /// unfinished run and the background behaviour allows resuming, continue.
  Future<bool> resumeIfNeeded(int bookId, int totalPages) async {
    final TranslationConfig tc;
    try {
      tc = await ref.read(translationConfigProvider.future);
    } catch (_) {
      return false;
    }
    if (tc.mode == TranslationMode.manual) return false;
    try {
      final overview =
          await ref.read(translationRepositoryProvider).getTranslationOverview(bookId);
      if (overview.error != null) return false;
      if (overview.translatedPages >= overview.totalPages ||
          overview.totalPages == 0) {
        return false;
      }
      // 随进度 resumes naturally via onVisiblePages; whole-book resumes now.
      if (tc.mode == TranslationMode.wholeBook &&
          tc.backgroundBehavior != TranslationBackgroundBehavior.cancel) {
        await startBook(bookId: bookId, totalPages: totalPages);
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Worker loop: keeps [_concurrency] pages in flight until the queue
  /// drains or the run is cancelled / paused.
  Future<void> _drain(int bookId, int gen) async {
    if (_draining) return;
    _draining = true;
    final repo = _safeRead(() => ref.read(translationRepositoryProvider));
    if (repo == null) {
      _draining = false;
      return;
    }
    try {
      while (!_disposed &&
          gen == _generation &&
          state.running &&
          !state.paused) {
        final concurrency =
            _safeRead(() => _concurrency) ?? 1;
        while (_inflight.length < concurrency && _pending.isNotEmpty) {
          final page = _pending.removeAt(0);
          _inflight.add(page);
          unawaited(_translateOne(repo, bookId, page, gen));
        }
        if (_inflight.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
    } finally {
      _draining = false;
    }
    if (!_disposed && gen == _generation) {
      await repo.cancelTranslation(bookId);
      state = state.copyWith(running: false, clearPage: true);
    }
  }

  Future<void> _translateOne(
    TranslationRepository repo,
    int bookId,
    int page,
    int gen,
  ) async {
    try {
      await for (final ev in repo.translatePage(bookId: bookId, page: page)) {
        if (gen != _generation) return;
        if (ev.error != null) {
          state = state.copyWith(error: ev.error);
        }
        if (ev.finished) break;
      }
      if (gen != _generation) return;
      state = state.copyWith(
        donePages: state.donePages + 1,
        currentPage: page,
        clearError: true,
      );
      // Invalidate rendered page images so an open pane shows this page.
      _safeRead(() {
        ref.read(translationRevisionProvider.notifier).state++;
        return 0;
      });
    } catch (e) {
      if (gen == _generation) {
        state = state.copyWith(error: e.toString());
      }
    } finally {
      _inflight.remove(page);
    }
  }
}

final translationQueueProvider =
    NotifierProvider<TranslationQueueNotifier, TranslationQueueState>(
        TranslationQueueNotifier.new);
