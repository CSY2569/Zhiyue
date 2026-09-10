import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_panel_side.dart';
import 'package:rbwa/src/rust/models/ai.dart';

import 'helpers/fake_ai_repo.dart';

/// The conversation list must open pinned to the bottom (newest turn), so a
/// long history does not show its oldest messages first.
void main() {
  testWidgets('chat view opens at the newest message (reverse list)',
      (tester) async {
    final repo = FakeAiRepo();
    // A thread with enough turns that it cannot all fit on screen.
    final created = await repo.createAiThread(
      title: '长对话',
      actionType: AiActionType.chat,
      bookId: null,
    );
    for (var i = 0; i < 30; i++) {
      await repo.appendAiMessage(
        threadId: created.id,
        role: AiRole.user,
        content: '问题 $i',
        actionType: AiActionType.chat,
      );
      await repo.appendAiMessage(
        threadId: created.id,
        role: AiRole.assistant,
        content: '回答 $i',
        actionType: AiActionType.chat,
      );
    }

    await tester.pumpWidget(ProviderScope(
      overrides: [aiRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, height: 400, child: AiPanelSide()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AiPanelSide)));
    // Open the thread so the chat view (not the guide / window list) shows.
    container.read(aiProvider.notifier).openThread(created.id);
    await tester.pumpAndSettle();

    // The conversation list is reversed -> its origin (and initial scroll
    // position) is the bottom, which is where the newest turn lives.
    final listView = tester.widget<ListView>(
      find
          .descendant(
            of: find.byType(AiPanelSide),
            matching: find.byType(ListView),
          )
          .first,
    );
    expect(listView.reverse, isTrue);

    // The newest messages are on screen; the oldest are scrolled away.
    expect(find.text('回答 29'), findsOneWidget);
    expect(find.text('问题 0'), findsNothing);
  });
}
