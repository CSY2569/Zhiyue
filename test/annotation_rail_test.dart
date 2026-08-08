import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/reader/widgets/sidebars/notes_rail.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Fake annotation source (no Rust / DB) so the sidebar can be tested in
/// isolation.
class _FakeAnnotationNotifier extends AnnotationNotifier {
  static List<TextAnnotation> data = const [];

  @override
  Future<List<TextAnnotation>> build() async => data;
}

/// Fake image-mark source for the merged sidebar.
class _FakeImageMarkNotifier extends ImageMarkNotifier {
  static List<ImageMark> data = const [];

  @override
  Future<List<ImageMark>> build() async => data;
}

TextAnnotation ann(
  int id,
  int page,
  TextAnnotationKind kind, {
  String? text,
  String? content,
}) =>
    TextAnnotation(
      id: id,
      bookId: 1,
      page: page,
      kind: kind,
      text: text,
      content: content,
      rects: const [NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.02)],
      color: null,
      createdAt: '2026-08-06 10:00:00',
      updatedAt: '2026-08-06 10:00:00',
    );

ImageMark mark(int id, int page, ImageMarkKind kind) => ImageMark(
      id: id,
      page: page,
      kind: kind,
      x: 0.5,
      y: 0.5,
      w: 0.2,
      h: 0.2,
      payload: kind == ImageMarkKind.sticky
          ? stickyPayload('贴上的便签')
          : brushPayload(const [Offset(0.4, 0.5), Offset(0.6, 0.5)]),
      style: '{}',
    );

Widget harness() => ProviderScope(
      overrides: [
        annotationProvider.overrideWith(_FakeAnnotationNotifier.new),
        imageMarkProvider.overrideWith(_FakeImageMarkNotifier.new),
      ],
      child: const MaterialApp(
        home: Scaffold(body: Row(children: [NotesRail()])),
      ),
    );

void main() {
  testWidgets('empty book shows the placeholder hint', (tester) async {
    _FakeAnnotationNotifier.data = const [];
    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('暂无标注'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lists annotations flat with per-kind filter chips',
      (tester) async {
    _FakeAnnotationNotifier.data = [
      ann(1, 0, TextAnnotationKind.highlight, text: 'first line'),
      ann(2, 0, TextAnnotationKind.note, text: 'second', content: 'note body'),
      ann(3, 2, TextAnnotationKind.underline, text: 'third line'),
    ];
    await tester.pumpWidget(harness());
    await tester.pump();

    // Flat list (no page headers): every entry visible.
    expect(find.text('第 1 页'), findsNothing);
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('note body'), findsOneWidget);
    expect(find.text('third line'), findsOneWidget);

    // Text-annotation filter chips are present (高亮/下划线/删除线/笔记).
    expect(find.text('高亮'), findsOneWidget);
    expect(find.text('下划线'), findsOneWidget);
    expect(find.text('删除线'), findsOneWidget);
    expect(find.text('笔记'), findsOneWidget);

    // Export bar is present.
    expect(find.text('Markdown'), findsOneWidget);
    expect(find.text('JSON'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping an entry jumps to its page', (tester) async {
    _FakeAnnotationNotifier.data = [
      ann(1, 4, TextAnnotationKind.highlight, text: 'page five text'),
    ];
    int? jumped;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        annotationProvider.overrideWith(_FakeAnnotationNotifier.new),
        imageMarkProvider.overrideWith(_FakeImageMarkNotifier.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Row(children: [NotesRail(onJump: (p) => jumped = p)]),
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('page five text'));
    expect(jumped, 4); // 0-indexed
    expect(tester.takeException(), isNull);
  });

  testWidgets('lists image marks flat alongside text annotations',
      (tester) async {
    _FakeAnnotationNotifier.data = [
      ann(1, 0, TextAnnotationKind.highlight, text: 'first line'),
    ];
    _FakeImageMarkNotifier.data = [
      mark(10, 0, ImageMarkKind.sticky),
      mark(11, 1, ImageMarkKind.brush),
    ];
    await tester.pumpWidget(harness());
    await tester.pump();

    // All entries in one flat list (no page headers, no text/image split).
    expect(find.text('第 1 页'), findsNothing);
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('贴上的便签'), findsOneWidget);
    expect(find.textContaining('画笔（'), findsOneWidget);

    // Image-mark controls: per-type filter chips + clear-all.
    expect(find.text('清空全部标记'), findsOneWidget);
    expect(find.text('图章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
