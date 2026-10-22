import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/note_popup.dart';
import 'package:rbwa/src/rust/models/annotation.dart';

/// Two notes, so the popup can be pointed at a different one while open.
final _notes = [
  TextAnnotation(
    id: 1,
    bookId: 1,
    page: 0,
    kind: TextAnnotationKind.highlight,
    source: 'original',
    text: '第一段',
    content: '第一条笔记',
    rects: const [NormRect(x: 0.1, y: 0.1, w: 0.2, h: 0.02)],
    color: null,
    createdAt: '2026-08-06 10:00:00',
    updatedAt: '2026-08-06 10:00:00',
  ),
  TextAnnotation(
    id: 2,
    bookId: 1,
    page: 0,
    kind: TextAnnotationKind.highlight,
    source: 'original',
    text: '第二段',
    content: '第二条笔记',
    rects: const [NormRect(x: 0.1, y: 0.3, w: 0.2, h: 0.02)],
    color: null,
    createdAt: '2026-08-06 10:00:00',
    updatedAt: '2026-08-06 10:00:00',
  ),
];

class _FakeAnnotations extends AnnotationNotifier {
  @override
  Future<List<TextAnnotation>> build() async => _notes;
}

/// Records the update calls so the test can assert what 保存 would write.
class _RecordingAnnotations extends AnnotationNotifier {
  final updates = <(int, String?)>[];

  @override
  Future<List<TextAnnotation>> build() async => _notes;

  @override
  Future<bool> updateContent(int id, String? content) async {
    updates.add((id, content));
    return true;
  }
}

Widget _host({AnnotationNotifier Function()? annotations}) => ProviderScope(
      overrides: [
        annotationProvider.overrideWith(annotations ?? _FakeAnnotations.new),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: Stack(children: [NotePopup()]),
        ),
      ),
    );

void main() {
  testWidgets('the editor reloads when the popup targets another note',
      (tester) async {
    // Opening a second note while the popup is already shown reuses the same
    // widget. The editor used to keep the first note's text, and 保存 then
    // overwrote the second note with it.
    final recording = _RecordingAnnotations();
    await tester.pumpWidget(_host(annotations: () => recording));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NotePopup)),
    );
    container.read(selectionProvider.notifier).openNote(1);
    await tester.pumpAndSettle();
    expect(find.text('第一条笔记'), findsOneWidget);

    container.read(selectionProvider.notifier).openNote(2);
    await tester.pumpAndSettle();
    expect(find.text('第二条笔记'), findsOneWidget);
    expect(find.text('第一条笔记'), findsNothing);

    // Saving writes the text the editor now shows, to the CURRENT note.
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(recording.updates, [(2, '第二条笔记')]);
  });
}
