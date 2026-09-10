import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_panel_side.dart';
import 'package:rbwa/features/ai/widgets/message_bubble.dart';
import 'package:rbwa/src/rust/models/ai.dart';

import 'helpers/fake_ai_repo.dart';

/// Settings stub that reports a chosen AI panel width.
class _FakeSettings extends SettingsRepository {
  _FakeSettings(this.panelWidth);
  final double panelWidth;

  @override
  Future<String?> getSetting(String key) async =>
      key == 'panel_width_ai' ? panelWidth.toString() : null;

  @override
  Future<int> setSetting(String key, String value) async => 1;
}

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester,
  FakeAiRepo repo,
  double width,
) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      aiRepositoryProvider.overrideWithValue(repo),
      settingsRepositoryProvider.overrideWithValue(_FakeSettings(width)),
    ],
    child: const MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(height: 600, child: AiPanelSide()),
        ),
      ),
    ),
  ));
  final container =
      ProviderScope.containerOf(tester.element(find.byType(AiPanelSide)));
  await container
      .read(aiProvider.notifier)
      .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
  await tester.pumpAndSettle();
  return container;
}

/// The maxWidth the panel passes to its message bubbles.
double _bubbleMaxWidth(WidgetTester tester) =>
    tester.widget<AiMessageBubble>(find.byType(AiMessageBubble).first).maxWidth;

void main() {
  testWidgets('bubbles fill the panel width instead of a fixed 260',
      (tester) async {
    // 500-wide panel: bubbles should span the width minus the list padding.
    await _pumpPanel(tester, FakeAiRepo(), 500);
    expect(_bubbleMaxWidth(tester), 480);
  });

  testWidgets('bubble width tracks a narrower panel', (tester) async {
    await _pumpPanel(tester, FakeAiRepo(), 360);
    expect(_bubbleMaxWidth(tester), 340);
  });

  testWidgets('a below-minimum panel width is clamped, bubbles stay sane',
      (tester) async {
    // The layout clamps the panel to its minimum (240), so bubbles remain
    // positive even if a tiny width is configured.
    await _pumpPanel(tester, FakeAiRepo(), 120);
    expect(_bubbleMaxWidth(tester), 220);
  });
}
