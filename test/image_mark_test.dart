
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/annotation/widgets/image_mark_layer.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/annotation.dart'
    show ImageAnnotation, ImageAnnotationKind;
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine, OcrResult;

/// Fake reader repository: image marks persist in memory; OCR returns
/// nothing / a canned failure (the real engine is a stub until the models
/// are installed).
class _FakeReaderRepo extends ReaderRepository {
  final marks = <ImageAnnotation>[];
  int _nextId = 1;
  bool scanFails = true;
  int listCalls = 0;

  @override
  Future<List<ImageAnnotation>> listImageAnnotations(int bookId) async {
    listCalls++;
    return [...marks];
  }

  @override
  Future<rust.ImageMarkCreateResult> createImageAnnotation({
    required int bookId,
    required int page,
    required ImageAnnotationKind kind,
    required double x,
    required double y,
    double? w,
    double? h,
    required double rotation,
    required String payload,
    required String style,
  }) async {
    final id = _nextId++;
    marks.add(ImageAnnotation(
      id: id,
      bookId: bookId,
      page: page,
      kind: kind,
      x: x,
      y: y,
      w: w,
      h: h,
      rotation: rotation,
      payload: payload,
      style: style,
      createdAt: 'now',
    ));
    return rust.ImageMarkCreateResult(id: id, error: null);
  }

  @override
  Future<int> updateImageAnnotation({
    required int annotationId,
    required double x,
    required double y,
    double? w,
    double? h,
    required double rotation,
    required String payload,
    required String style,
  }) async {
    final i = marks.indexWhere((m) => m.id == annotationId);
    if (i < 0) return 0;
    final old = marks[i];
    marks[i] = ImageAnnotation(
      id: old.id,
      bookId: old.bookId,
      page: old.page,
      kind: old.kind,
      x: x,
      y: y,
      w: w,
      h: h,
      rotation: rotation,
      payload: payload,
      style: style,
      createdAt: old.createdAt,
    );
    return 1;
  }

  @override
  Future<int> deleteImageAnnotation(int annotationId) async {
    marks.removeWhere((m) => m.id == annotationId);
    return 1;
  }

  @override
  Future<rust.ScanPageResult> scanPage(
          int bookId, int page, rust.OcrMode mode) async =>
      scanFails
          ? rust.ScanPageResult(
              lines: const [], mode: 'high_precision', error: 'OCR 模型未安装')
          : rust.ScanPageResult(
              lines: [
                OcrLine(text: '你好世界', x: 0.1, y: 0.2, w: 0.5, h: 0.03, confidence: 0.98),
              ],
              mode: 'high_precision',
              error: null,
            );

  @override
  Future<OcrResult?> getPageOcr(int bookId, int page, rust.OcrMode mode) async =>
      null;
}

Book _book() => Book(
      id: 1,
      title: '扫描书',
      originalPath: '/x.pdf',
      storedPath: '/x.pdf',
      fileType: BookType.pdf,
      pageCount: 3,
      coverPath: null,
      favorite: false,
      categoryId: null,
      lastOpenedAt: null,
      importedAt: 'now',
    );

/// Let an invalidated async provider's rebuild land before reading state
/// (the rebuild is scheduled on the event loop; poll until the content stops
/// changing).
Future<void> _settle(ProviderContainer container) async {
  var last = 'initial';
  for (var i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final v = container.read(imageMarkProvider).valueOrNull;
    final now = v?.map((m) => '${m.id}:${m.x}:${m.y}').join(',') ?? 'null';
    if (now == last) return;
    last = now;
  }
}

ProviderContainer _container(_FakeReaderRepo repo) {
  final container = ProviderContainer(overrides: [
    readerRepositoryProvider.overrideWithValue(repo),
    viewerProvider.overrideWith((ref) {
      final n = ViewerNotifier(ref);
      n.state = ViewerState(
        book: _book(),
        pageCount: 3,
        currentPage: 1,
        zoom: 1.2,
        loading: false,
      );
      return n;
    }),
  ]);
  addTearDown(container.dispose);
  return container;
}

ImageMark _brush() => ImageMark(
      page: 0,
      kind: ImageMarkKind.brush,
      x: 0.5,
      y: 0.5,
      w: 0.3,
      h: 0.2,
      payload: brushPayload(const [Offset(0.4, 0.5), Offset(0.5, 0.5), Offset(0.6, 0.5)]),
      style: const ImageMarkStyle(color: '#e53935').toJson(),
    );

void main() {
  group('模型序列化', () {
    test('brush payload roundtrip', () {
      final payload = brushPayload(const [Offset(0.1, 0.2), Offset(0.3, 0.4)]);
      final mark = ImageMark(
        page: 0,
        kind: ImageMarkKind.brush,
        x: 0.5,
        y: 0.5,
        payload: payload,
        style: const ImageMarkStyle().toJson(),
      );
      expect(mark.brushPoints, const [Offset(0.1, 0.2), Offset(0.3, 0.4)]);
    });

    test('sticky / shape / stamp payload accessors', () {
      final sticky = ImageMark(
        page: 0, kind: ImageMarkKind.sticky, x: 0.5, y: 0.5,
        payload: stickyPayload('hello'), style: '{}',
      );
      expect(sticky.stickyText, 'hello');

      final shape = ImageMark(
        page: 0, kind: ImageMarkKind.shape, x: 0.5, y: 0.5,
        payload: shapePayload('arrow'), style: '{}',
      );
      expect(shape.shapeType, 'arrow');

      final stamp = ImageMark(
        page: 0, kind: ImageMarkKind.stamp, x: 0.5, y: 0.5,
        payload: stampPayload('stamps/a.png'), style: '{}',
      );
      expect(stamp.stampFile, 'stamps/a.png');
    });

    test('style JSON roundtrip', () {
      const style = ImageMarkStyle(color: '#1e88e5', strokeWidth: 5, fill: true, fontSize: 16);
      final parsed = ImageMarkStyle.fromJson(style.toJson());
      expect(parsed.color, '#1e88e5');
      expect(parsed.strokeWidth, 5);
      expect(parsed.fill, isTrue);
      expect(parsed.fontSize, 16);
    });
  });

  group('ImageMarkNotifier', () {
    test('create persists and undo/redo restore the list', () async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      final notifier = container.read(imageMarkProvider.notifier);

      expect(await notifier.create(_brush()), isTrue);
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull!.length, 1);
      expect(notifier.canUndo, isTrue);
      expect(repo.marks.length, 1);

      // Undo deletes the mark (DB + list), redo recreates it.
      await notifier.undo();
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull, isEmpty);
      expect(repo.marks, isEmpty);

      await notifier.redo();
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull!.length, 1);
      expect(repo.marks.length, 1);
    });

    test('delete pushes undo that recreates the mark', () async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      final notifier = container.read(imageMarkProvider.notifier);

      await notifier.create(_brush());
      await _settle(container);
      final mark = container.read(imageMarkProvider).valueOrNull!.single;

      await notifier.delete(mark.id);
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull, isEmpty);

      await notifier.undo();
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull!.length, 1);
      expect(repo.marks.length, 1);
    });

    test('updateMark changes geometry and undo restores it', () async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      final notifier = container.read(imageMarkProvider.notifier);

      await notifier.create(_brush());
      await _settle(container);
      final mark = container.read(imageMarkProvider).valueOrNull!.single;
      await notifier.updateMark(mark.copyWith(x: 0.9, y: 0.1), before: mark);
      await _settle(container);
      final moved = container.read(imageMarkProvider).valueOrNull!.single;
      expect(moved.x, 0.9);
      expect(moved.y, 0.1);

      await notifier.undo();
      await _settle(container);
      final restored = container.read(imageMarkProvider).valueOrNull!.single;
      expect(restored.x, 0.5);
    });

    test('clearAll removes every mark', () async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      final notifier = container.read(imageMarkProvider.notifier);

      await notifier.create(_brush());
      await _settle(container);
      await notifier.create(_brush().copyWith(x: 0.2));
      await _settle(container);
      await notifier.clearAll();
      await _settle(container);
      expect(container.read(imageMarkProvider).valueOrNull, isEmpty);
      expect(repo.marks, isEmpty);
    });
  });

  group('图层筛选', () {
    test('visibility toggles hide kinds from the layer', () async {
      final container = _container(_FakeReaderRepo());
      final vis = container.read(markVisibilityProvider.notifier);
      expect(container.read(markVisibilityProvider),
          ImageMarkKind.values.toSet());

      vis.toggle(ImageMarkKind.brush);
      expect(container.read(markVisibilityProvider),
          isNot(contains(ImageMarkKind.brush)));
      vis.toggle(ImageMarkKind.brush);
      expect(container.read(markVisibilityProvider),
          contains(ImageMarkKind.brush));
    });
  });

  group('ImageMarkLayer 交互', () {
    testWidgets('brush tool drag creates a brush mark on pan end',
        (tester) async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 600, child: ImageMarkLayer(page: 0)),
            ),
          ),
        ),
      ));

      // Arm the brush tool.
      container.read(markToolProvider.notifier).setTool(MarkTool.brush);
      await tester.pump();

      // Drag a stroke across the page (center of the layer); several moves
      // so the brush accumulates >2 points (the layer drops tiny strokes).
      final gesture = await tester.startGesture(const Offset(250, 300));
      await gesture.moveTo(const Offset(260, 302));
      await gesture.moveTo(const Offset(280, 305));
      await gesture.moveTo(const Offset(300, 308));
      await gesture.moveTo(const Offset(320, 310));
      await gesture.up();
      await tester.pumpAndSettle();

      // A brush mark with 3 points was persisted.
      expect(repo.marks, hasLength(1));
      expect(repo.marks.single.kind, ImageAnnotationKind.brush);
      final mark = container.read(imageMarkProvider).valueOrNull!.single;
      expect(mark.brushPoints, hasLength(3));

      // The stroke starts exactly at the pointer-down point (the layer
      // anchors on the down position, not the slop-shifted pan start).
      // Layer sits at (200, 0) inside the 800x600 test window.
      final first = mark.brushPoints.first;
      expect(first.dx, closeTo(50 / 400, 0.02)); // 250 - 200
      expect(first.dy, closeTo(300 / 600, 0.02));
    });

    testWidgets('stamp tap places the mark exactly at the pointer',
        (tester) async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 600, child: ImageMarkLayer(page: 0)),
            ),
          ),
        ),
      ));

      // Pick a stamp image and arm the stamp tool.
      container
          .read(markToolProvider.notifier)
          .setStampFile('/tmp/stamp.png');
      container.read(markToolProvider.notifier).setTool(MarkTool.stamp);
      await tester.pump();

      // Tap at a known spot: the mark center must be exactly there.
      await tester.tapAt(const Offset(300, 200));
      await tester.pumpAndSettle();

      expect(repo.marks, hasLength(1));
      expect(repo.marks.single.kind, ImageAnnotationKind.stamp);
      final mark = container.read(imageMarkProvider).valueOrNull!.single;
      expect(mark.x, closeTo(100 / 400, 0.001)); // 300 - 200 (layer origin)
      expect(mark.y, closeTo(200 / 600, 0.001));
    });

    testWidgets('stamp tool without a picked image shows a hint',
        (tester) async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 600, child: ImageMarkLayer(page: 0)),
            ),
          ),
        ),
      ));

      container.read(markToolProvider.notifier).setTool(MarkTool.stamp);
      await tester.pump();
      await tester.tapAt(const Offset(200, 300));
      await tester.pump();

      expect(find.text('请先在工具栏选择图章图片'), findsOneWidget);
      expect(repo.marks, isEmpty);
    });

    testWidgets('select drag moves the mark with the pointer (no runaway)',
        (tester) async {
      final repo = _FakeReaderRepo();
      final container = _container(repo);
      final notifier = container.read(imageMarkProvider.notifier);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, height: 600, child: ImageMarkLayer(page: 0)),
            ),
          ),
        ),
      ));

      // A sticky note at (0.3, 0.3), size 0.3 x 0.1.
      await notifier.create(ImageMark(
        page: 0,
        kind: ImageMarkKind.sticky,
        x: 0.3,
        y: 0.3,
        w: 0.3,
        h: 0.1,
        payload: stickyPayload('hi'),
        style: const ImageMarkStyle().toJson(),
      ));
      await tester.pumpAndSettle();

      // Arm the select tool and drag from the note's center.
      container.read(markToolProvider.notifier).setTool(MarkTool.select);
      await tester.pump();
      // Note center on screen: layer origin (200, 0) + (0.3*400, 0.3*600).
      final down = const Offset(320, 180);
      final gesture = await tester.startGesture(down);
      await gesture.moveTo(const Offset(330, 190));
      await gesture.moveTo(const Offset(360, 205));
      await gesture.moveTo(const Offset(400, 225));
      await gesture.moveTo(const Offset(440, 245));
      await gesture.up();
      await tester.pumpAndSettle();

      // The mark follows the pointer: its center ends near the final
      // pointer position (trailing at most the touch-slop consumed before
      // the drag started). The runaway bug made it overshoot far past the
      // cursor because every move re-applied the whole delta.
      final moved = container.read(imageMarkProvider).valueOrNull!.single;
      final screenX = moved.x * 400 + 200; // layer origin at (200, 0)
      final screenY = moved.y * 600;
      expect(screenX, lessThan(440 + 1)); // never ahead of the pointer
      expect(screenX, greaterThan(440 - 60)); // trails within slop distance
      expect(screenY, lessThan(245 + 1));
      expect(screenY, greaterThan(245 - 60));
      expect(moved.kind, ImageMarkKind.sticky);
      expect(moved.stickyText, 'hi');
    });
  });
}
