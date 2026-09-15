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
    this.totalPages = 0,
    this.donePages = 0,
    this.error,
  });

  final int? bookId;
  final bool running;
  final int totalPages;
  final int donePages;
  final String? error;

  double get progress =>
      totalPages == 0 ? 0 : (donePages / totalPages).clamp(0.0, 1.0);

  TranslationQueueState copyWith({
    int? bookId,
    bool? running,
    int? totalPages,
    int? donePages,
    String? error,
    bool clearBook = false,
    bool clearError = false,
  }) =>
      TranslationQueueState(
        bookId: clearBook ? null : (bookId ?? this.bookId),
        running: running ?? this.running,
        totalPages: totalPages ?? this.totalPages,
        donePages: donePages ?? this.donePages,
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

  /// Pages the AUTO queue stops retrying after a failure, so a persistent
  /// error (bad key, quota exhausted) cannot hot-loop on every page turn.
  /// 「翻译本页」 bypasses this and always retries.
  final Set<int> _failed = {};

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
  /// `1..totalPages`. Already-cached pages are skipped (`getTranslatedPages`
  /// seeds [donePages] in one call; it also filters rows stamped by an older
  /// extractor, so stale pages are redone).
  Future<void> startBook({required int bookId, required int totalPages}) async {
    final repo = ref.read(translationRepositoryProvider);
    if (state.running) {
      // A different book while one is running: apply the background rule.
      // `cancel` and `pause_resume` both stop issuing pages for the current
      // book; the pause_resume "resume on return" falls out of
      // [resumeIfNeeded] + cached-page skipping (a paused flag never resumed
      // on its own -- removed as dead logic).
      final behavior = ref
              .read(translationConfigProvider)
              .valueOrNull
              ?.backgroundBehavior ??
          TranslationBackgroundBehavior.ask;
      if (behavior != TranslationBackgroundBehavior.continue_) {
        await cancel();
      }
      // `continue` falls through: both books share this single queue, so the
      // new request is appended after the current run (simplest safe policy).
    }

    _generation++;
    final gen = _generation;
    _failed.clear();
    _inflight.clear();

    // Seed progress from the cache: ONE batched read instead of a
    // per-page probe (each probe re-read the config from the core).
    final done = <int>{};
    try {
      done.addAll(await repo.getTranslatedPages(bookId));
    } catch (_) {}

    _pending
      ..clear()
      ..addAll([
        for (var p = 1; p <= totalPages; p++)
          if (!done.contains(p)) p,
      ]);

    await repo.startBookTranslation(bookId);
    // A cancel() during the seeding awaits above bumped the generation:
    // honour it instead of resurrecting the run.
    if (gen != _generation) return;
    state = TranslationQueueState(
      bookId: bookId,
      running: true,
      totalPages: totalPages,
      donePages: done.length.clamp(0, totalPages),
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
      clearBook: true,
    );
  }

  /// Resumes an interrupted whole-book run (plan §9 自动续传): the overview
  /// shows unfinished work and the background behaviour allows resuming.
  Future<bool> resumeIfNeeded(int bookId, int totalPages) async {
    final TranslationConfig tc;
    try {
      tc = await ref.read(translationConfigProvider.future);
    } catch (_) {
      return false;
    }
    if (tc.mode == TranslationMode.manual) return false;
    try {
      final overview = await ref
          .read(translationRepositoryProvider)
          .getTranslationOverview(bookId);
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

  /// Called when the reader's visible pages change (plan §10 随进度): enqueues
  /// the visible pages plus the next two, skipping cached / failed ones.
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

    final targets = <int>{
      for (final p in visible)
        for (var i = 0; i < 3; i++)
          if (p + i >= 1) p + i,
    };

    final repo = ref.read(translationRepositoryProvider);
    // One batched cache read for the whole turn (probing every target
    // re-read the config per page).
    var done = <int>{};
    try {
      done = (await repo.getTranslatedPages(bookId)).toSet();
    } catch (_) {
      // Cache unreadable: enqueue everything not already queued -- worst case
      // a cheap cache-hit re-run, never a lost translation.
    }

    _pending.addAll(
      targets.where((p) =>
          !_inflight.contains(p) &&
          !_pending.contains(p) &&
          !done.contains(p) &&
          !_failed.contains(p)),
    );
    if (_pending.isEmpty) return;

    try {
      await repo.startBookTranslation(bookId);
    } catch (_) {
      return;
    }
    // Re-arm the run: the previous batch's drain set running=false when it
    // emptied, and every later page turn must revive it (regression: only
    // the FIRST batch ever translated -- the state kept bookId, so this
    // branch never fired again and _drain exited on !running immediately).
    state = state.copyWith(bookId: bookId, running: true, clearError: true);
    await _drain(bookId, _generation);
  }

  /// Worker loop: keeps [_concurrency] pages in flight until the queue
  /// drains or the run is cancelled.
  Future<void> _drain(int bookId, int gen) async {
    if (_draining) return;
    _draining = true;
    final repo = _safeRead(() => ref.read(translationRepositoryProvider));
    if (repo == null) {
      _draining = false;
      return;
    }
    try {
      while (!_disposed && gen == _generation && state.running) {
        final concurrency = _safeRead(() => _concurrency) ?? 1;
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
      state = state.copyWith(running: false);
    }
  }

  Future<void> _translateOne(
    TranslationRepository repo,
    int bookId,
    int page,
    int gen,
  ) async {
    var hadError = false;
    try {
      await for (final ev in repo.translatePage(bookId: bookId, page: page)) {
        if (gen != _generation) return;
        if (ev.error != null) {
          hadError = true;
          state = state.copyWith(error: ev.error);
        }
        if (ev.finished) break;
      }
      if (gen != _generation) return;
      // A failed page is NOT cached by the core: counting it as done would
      // lie about progress and never retry would hot-loop. Park it in
      // [_failed]; the manual 翻译本页 button still retries it.
      if (hadError) {
        _failed.add(page);
        return;
      }
      state = state.copyWith(
        donePages: state.donePages + 1,
        clearError: true,
      );
      // Invalidate rendered page images so an open pane shows this page.
      _safeRead(() {
        ref.read(translationRevisionProvider.notifier).state++;
        return 0;
      });
    } catch (e) {
      if (gen == _generation) {
        _failed.add(page);
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
