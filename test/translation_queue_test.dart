import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_queue_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/fake_translation_repo.dart';

ProviderContainer _container(FakeTranslationRepo repo) {
  final c = ProviderContainer(overrides: [
    translationRepositoryProvider.overrideWithValue(repo),
  ]);
  addTearDown(c.dispose);
  return c;
}

TranslationConfig _config({
  TranslationMode mode = TranslationMode.wholeBook,
  TranslationBackgroundBehavior background =
      TranslationBackgroundBehavior.continue_,
  int concurrency = 2,
}) =>
    TranslationConfig(
      provider: TranslationProviderKind.reuseAi,
      baseUrl: null,
      apiKey: null,
      model: null,
      sourceLang: 'auto',
      mode: mode,
      backgroundBehavior: background,
      autoOcr: true,
      concurrency: concurrency,
      cacheLimitMb: 2048,
    );

void main() {
  test('whole-book run translates 1..N and reports progress', () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    // Seed the config provider so concurrency resolves.
    c.read(translationConfigProvider.notifier).state = AsyncData(_config());

    await c
        .read(translationQueueProvider.notifier)
        .startBook(bookId: 1, totalPages: 3);

    final state = c.read(translationQueueProvider);
    expect(state.running, isFalse);
    expect(state.donePages, 3);
    expect(state.totalPages, 3);
    // All three pages were requested, and the registration was cleared.
    expect(repo.translateCalls.map((e) => e.$2).toSet(), {1, 2, 3});
    expect(repo.started, contains(1));
    expect(repo.cancelled, contains(1));
  });

  test('cached pages are skipped on a resume', () async {
    final repo = FakeTranslationRepo();
    // Page 1 already cached.
    repo.cache[1] = PageTranslation(
      page: 1,
      targetLang: '中文',
      provider: 'reuse_ai',
      sourceHash: 'h',
      paragraphs: const [],
      coverage: 1.0,
    );
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state = AsyncData(_config());

    await c
        .read(translationQueueProvider.notifier)
        .startBook(bookId: 1, totalPages: 3);

    // Page 1 is not re-requested; 2 and 3 are.
    final requested = repo.translateCalls.map((e) => e.$2).toSet();
    expect(requested, {2, 3});
    expect(c.read(translationQueueProvider).donePages, 3);
  });

  test('cancel stops the run and clears the registration', () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state = AsyncData(_config());
    final n = c.read(translationQueueProvider.notifier);

    // Start a large run in the background, then cancel immediately.
    final run = n.startBook(bookId: 1, totalPages: 50);
    await n.cancel();
    await run;
    expect(c.read(translationQueueProvider).running, isFalse);
    expect(c.read(translationQueueProvider).bookId, isNull);
    // The run was abandoned before finishing all 50 pages.
    expect(repo.translateCalls.length, lessThan(50));
  });

  test('with_progress enqueues visible + next two, skipping cached', () async {
    final repo = FakeTranslationRepo();
    repo.cache[5] = PageTranslation(
      page: 5,
      targetLang: '中文',
      provider: 'reuse_ai',
      sourceHash: 'h',
      paragraphs: const [],
      coverage: 1.0,
    );
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state =
        AsyncData(_config(mode: TranslationMode.withProgress));

    await c
        .read(translationQueueProvider.notifier)
        .onVisiblePages(1, [5]);

    final requested = repo.translateCalls.map((e) => e.$2).toSet();
    // Visible 5 is cached; 6 and 7 are enqueued.
    expect(requested, isNot(contains(5)));
    expect(requested, containsAll([6, 7]));
  });

  test('manual mode does not auto-enqueue', () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state =
        AsyncData(_config(mode: TranslationMode.manual));

    await c        .read(translationQueueProvider.notifier)
        .onVisiblePages(1, [5]);

    expect(repo.translateCalls, isEmpty);
  });

  test('resumeIfNeeded starts an unfinished whole-book run', () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state = AsyncData(
        _config(background: TranslationBackgroundBehavior.pauseResume));

    final resumed = await c
        .read(translationQueueProvider.notifier)
        .resumeIfNeeded(1, 4);
    expect(resumed, isTrue);
    // The overview reports 0/10 translated, so a run starts.
    expect(repo.translateCalls, isNotEmpty);
  });

  test('resumeIfNeeded does nothing in manual mode', () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state =
        AsyncData(_config(mode: TranslationMode.manual));

    final resumed = await c
        .read(translationQueueProvider.notifier)
        .resumeIfNeeded(1, 4);
    expect(resumed, isFalse);
    expect(repo.translateCalls, isEmpty);
  });

  /// Regression for the reported "没有调用 API 的入口": the reader's page
  /// listener calls `onVisiblePages` the moment a book opens, but the config
  /// loads ASYNCHRONOUSLY from Rust. Reading `valueOrNull` synchronously there
  /// returned null and bailed out forever, so 随进度 mode never called the API.
  /// The method must await the config future instead.
  test('onVisiblePages awaits an unloaded config instead of bailing out',
      () async {
    final repo = FakeTranslationRepo();
    // Fresh container: the config provider has NOT been read/loaded yet, and
    // FakeTranslationRepo.getTranslationConfig completes asynchronously.
    final c = _container(repo);
    expect(c.read(translationConfigProvider).hasValue, isFalse,
        reason: 'precondition: config not loaded yet');

    // Called before anything else touches the config -- the exact race.
    await c
        .read(translationQueueProvider.notifier)
        .onVisiblePages(1, [2]);

    expect(repo.translateCalls, isNotEmpty,
        reason: '随进度 must enqueue once the config resolves');
  });

  /// Regression: a finished batch set `running=false` but kept `bookId`, so
  /// the next page turn skipped the re-arm branch and `_drain` exited on
  /// `!running` immediately -- only the FIRST batch ever translated.
  test('a finished batch re-arms when the visible pages change again',
      () async {
    final repo = FakeTranslationRepo();
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state =
        AsyncData(_config(mode: TranslationMode.withProgress));

    // Batch 1: pages 1-3 translate.
    await c.read(translationQueueProvider.notifier).onVisiblePages(1, [1]);
    expect(repo.translateCalls.map((e) => e.$2).toSet(), {1, 2, 3});

    // Batch 2 (page turn): page 4 must still be enqueued.
    await c.read(translationQueueProvider.notifier).onVisiblePages(1, [2]);
    expect(repo.translateCalls.map((e) => e.$2), contains(4),
        reason: 'the queue must re-arm for every page turn, not just the first');
  });

  /// Regression: a failed page used to count as done (progress lied) and was
  /// re-enqueued on every page turn (hot-loop on a persistent error). It must
  /// be parked until the user retries manually.
  test('a failed page is not counted done and is not auto-retried',
      () async {
    final repo = FakeTranslationRepo()..failTranslate = true;
    final c = _container(repo);
    c.read(translationConfigProvider.notifier).state =
        AsyncData(_config(mode: TranslationMode.withProgress));

    await c.read(translationQueueProvider.notifier).onVisiblePages(1, [1]);
    expect(repo.translateCalls.map((e) => e.$2).toSet(), {1, 2, 3});
    expect(c.read(translationQueueProvider).donePages, 0,
        reason: 'failed pages must not count as done');

    // The failure clears; new pages go out but the failed ones stay parked.
    repo.failTranslate = false;
    await c.read(translationQueueProvider.notifier).onVisiblePages(1, [5]);
    expect(repo.translateCalls.map((e) => e.$2).toSet(), {1, 2, 3, 5, 6, 7});
    expect(c.read(translationQueueProvider).donePages, 3);
  });
}
