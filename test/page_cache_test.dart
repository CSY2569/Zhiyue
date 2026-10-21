import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

import 'helpers/widget_harness.dart';

/// Counts extractions and lets a test hold the response open.
class _GatedRepo extends ReaderRepository {
  _GatedRepo({this.gate, this.delay});

  final Completer<void>? gate;
  final Duration? delay;
  int extractCalls = 0;

  @override
  Future<rust.CharBoxResult> extractText(int bookId, int page) async {
    extractCalls++;
    if (gate != null) await gate!.future;
    if (delay != null) await Future<void>.delayed(delay!);
    return rust.CharBoxResult(
      boxes: [CharBox(char: '$bookId:$page', x: 0, y: 0, w: 1, h: 1)],
      error: null,
    );
  }
}

void main() {
  test('concurrent getOrFetch calls share one extraction', () async {
    final repo = _GatedRepo(delay: const Duration(milliseconds: 20));
    final container = ProviderContainer(
      overrides: [
        readerRepositoryProvider.overrideWithValue(repo),
        defaultViewer(),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(charBoxCacheProvider.notifier);
    // Three layers (selection, markers, search hits) preload the same page
    // on mount; only one FFI call may go out.
    final results = await Future.wait([
      notifier.getOrFetch(1, 0),
      notifier.getOrFetch(1, 0),
      notifier.getOrFetch(1, 0),
    ]);
    expect(repo.extractCalls, 1);
    expect(results[0], same(results[1]));
    expect(results[0].single.char, '1:0');

    // A hit after completion is served from the cache.
    await notifier.getOrFetch(1, 0);
    expect(repo.extractCalls, 1);
  });

  test('a result arriving after a book switch is not cached', () async {
    final gate = Completer<void>();
    final repo = _GatedRepo(gate: gate);
    final container = ProviderContainer(
      overrides: [
        readerRepositoryProvider.overrideWithValue(repo),
        defaultViewer(),
      ],
    );
    addTearDown(container.dispose);

    final notifier = container.read(charBoxCacheProvider.notifier);
    final pending = notifier.getOrFetch(1, 0);

    // Switch books while the extraction is in flight.
    container.read(viewerProvider.notifier).state = ViewerState(
      book: testBook(id: 2),
      pageCount: 3,
      loading: false,
    );
    expect(container.read(charBoxCacheProvider), isEmpty);

    gate.complete();
    final boxes = await pending;
    expect(boxes.single.char, '1:0');
    // The new book's page 0 must not be served book 1's geometry.
    expect(container.read(charBoxCacheProvider), isEmpty);
    expect(await notifier.getOrFetch(2, 0), isA<List<CharBox>>());
    expect(repo.extractCalls, 2);
    expect(container.read(charBoxCacheProvider)[0]!.single.char, '2:0');
  });
}
