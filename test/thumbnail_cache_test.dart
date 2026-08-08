import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'helpers/widget_harness.dart';
import 'package:rbwa/features/reader/widgets/sidebars/thumbnail_rail.dart';
import 'package:rbwa/src/rust/api.dart' as rust;

/// Counts renderThumbnail calls so the cache behavior is observable.
class _FakeRepo extends ReaderRepository {
  int renderCount = 0;

  @override
  Future<rust.PageRenderResult> renderThumbnail(
    int bookId,
    int page,
    int maxSize,
  ) async {
    renderCount++;
    const w = 100, h = 141;
    return rust.PageRenderResult(
      width: w,
      height: h,
      rgba: Uint8List(w * h * 4),
      error: null,
    );
  }
}

Widget _rail() => ProviderScope(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(_FakeRepo()),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              height: 600,
              child: ThumbnailRail(onJump: _noop),
            ),
          ),
        ),
      ),
    );

void _noop(int page) {}

void main() {
  testWidgets('thumbnails render once and are reused from cache',
      (tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(_rail());
      await tester.pump();
      // Let pdfium(fake)-render + decode settle.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();

      final repo = (ProviderScope.containerOf(
        tester.element(find.byType(ThumbnailRail)),
      ).read(readerRepositoryProvider)) as _FakeRepo;
      expect(repo.renderCount, 3, reason: 'all 3 pages rendered once');
      expect(find.byType(RawImage), findsNWidgets(3));
      expect(tester.takeException(), isNull);

      // Simulate closing and re-opening the sidebar: the rail is rebuilt,
      // but thumbnails must come from the cache, not pdfium.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();
      await tester.pumpWidget(_rail());
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pump();

      expect(repo.renderCount, 3, reason: 'cache hit: no re-render');
      expect(find.byType(RawImage), findsNWidgets(3));
      expect(tester.takeException(), isNull);
    });
  });
}
