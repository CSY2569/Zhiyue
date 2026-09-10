import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/widgets/panel_resize_handle.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/src/rust/models/ai.dart';

import 'helpers/fake_ai_repo.dart';

/// Settings stub so the layout provider can hydrate without Rust.
class _FakeSettings extends SettingsRepository {
  @override
  Future<String?> getSetting(String key) async => null;
  @override
  Future<int> setSetting(String key, String value) async => 1;
}

ProviderScope _scope(FakeAiRepo repo) => ProviderScope(
      overrides: [
        aiRepositoryProvider.overrideWithValue(repo),
        settingsRepositoryProvider.overrideWithValue(_FakeSettings()),
      ],
      // Wide enough for the default 440px card.
      child: const MaterialApp(
        home: Scaffold(body: Stack(children: [ResultCard()])),
      ),
    );

void main() {
  testWidgets('dragging the corner handle grows the card', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    expect(container.read(panelLayoutProvider).cardSize, const Size(440, 360));

    await tester.drag(
        find.byKey(const Key('card-resize-handle')), const Offset(100, 60));
    await tester.pumpAndSettle();

    final size = container.read(panelLayoutProvider).cardSize;
    expect(size.width, greaterThan(440));
    expect(size.height, greaterThan(360));
  });

  testWidgets('card bubbles reflow with the width', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    // Widen the card well past the default and check the bubble constraint
    // grows with it (was a hardcoded 380).
    container
        .read(panelLayoutProvider.notifier)
        .resizeCard(const Offset(300, 0));
    await tester.pumpAndSettle();

    final cardWidth = container.read(panelLayoutProvider).cardSize.width;
    expect(cardWidth, greaterThan(600));
    // The card's SizedBox reflects the new width.
    final sizedBox = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(ResultCard),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(sizedBox.width, cardWidth);
  });

  testWidgets('resize handle exists alongside the other resize handles',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('card-resize-handle')), findsOneWidget);
    // Sanity: the shared sidebar handle type is distinct from the card grip.
    expect(find.byType(PanelResizeHandle), findsNothing);
  });
}
