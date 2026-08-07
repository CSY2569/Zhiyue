import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/reader/widgets/sidebars/notes_rail.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Fake annotation source (no Rust / DB) so the sidebar can be tested in
/// isolation.
class _FakeAnnotationNotifier extends AnnotationNotifier {
  static List<TextAnnotation> data = const [];

  @override
  Future<List<TextAnnotation>> build() async => data;
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

Widget harness() => ProviderScope(
      overrides: [annotationProvider.overrideWith(_FakeAnnotationNotifier.new)],
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

  testWidgets('groups annotations by page with icons and text', (tester) async {
    _FakeAnnotationNotifier.data = [
      ann(1, 0, TextAnnotationKind.highlight, text: 'first line'),
      ann(2, 0, TextAnnotationKind.note, text: 'second', content: 'note body'),
      ann(3, 2, TextAnnotationKind.underline, text: 'third line'),
    ];
    await tester.pumpWidget(harness());
    await tester.pump();

    // Group headers only for pages that have annotations (page 2 is absent).
    expect(find.text('第 1 页'), findsOneWidget);
    expect(find.text('第 3 页'), findsOneWidget);
    expect(find.text('第 2 页'), findsNothing);

    // Entries show the selected text and note preview.
    expect(find.text('first line'), findsOneWidget);
    expect(find.text('note body'), findsOneWidget);
    expect(find.text('third line'), findsOneWidget);

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
      overrides: [annotationProvider.overrideWith(_FakeAnnotationNotifier.new)],
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
}
