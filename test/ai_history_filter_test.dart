import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';

import 'helpers/fake_ai_repo.dart';

/// The stream-error note [AiStreamSession] appends on a failed turn
/// (`\n\n> ⚠️ …`) must stay visible in the thread but never replay into a
/// later request (6.5.2): the provider would otherwise see a fake assistant
/// answer quoting an HTTP error, and every later turn would carry it.
/// Regression test for the `_replayHistory` filter in ai_provider.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Flush the fake stream's microtasks until the turn finishes.
  Future<void> settleStream(ProviderContainer container) async {
    for (var i = 0;
        i < 100 && container.read(aiProvider).streamingThreadId != null;
        i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('replayed history drops the ⚠️ error note of failed turns', () async {
    final repo = FakeAiRepo();
    final container = ProviderContainer(
      overrides: [aiRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    // Turn 1 answers normally.
    final notifier = container.read(aiProvider.notifier);
    await notifier.askQuestion('问题一', bookId: null, bookTitle: null);
    await settleStream(container);

    // Turn 2 fails: the ⚠️ note lands in the thread as the answer.
    repo.failStream = true;
    final threadId = container.read(aiProvider).threads.first.id;
    await notifier.sendMessage(threadId, '问题二');
    await settleStream(container);
    expect(
      container
          .read(aiProvider)
          .threadOf(threadId)!
          .messages
          .map((m) => m.content),
      contains(contains('> ⚠️')),
    );

    // Turn 3 succeeds: the replayed history must not carry the ⚠️ note (the
    // failed turn had no text, so it drops out of the replay entirely).
    repo.failStream = false;
    await notifier.sendMessage(threadId, '问题三');
    await settleStream(container);

    final history = repo.histories.last;
    expect(history, hasLength(3));
    for (final m in history) {
      expect(m.content, isNot(contains('⚠️')));
    }
  });
}
