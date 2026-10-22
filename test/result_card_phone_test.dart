import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';

/// The AI answer card must be FLOATING on phones too (it used to be docked as
/// a bottom sheet). A floating card lets the reader keep seeing the page and
/// the selection it came from.
void main() {
  Future<void> pumpCard(WidgetTester tester, Size logical) async {
    tester.view.physicalSize = logical * 2;
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              // Show the card the way an AI action does: the notifier exposes
              // visibility through the stream, so seed it directly.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final container = ProviderScope.containerOf(context);
                final n = container.read(aiProvider.notifier);
                // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                n.state = n.state.copyWith(cardVisible: true);
              });
              return const Stack(children: [ResultCard()]);
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('phone: the card floats, it is not a full-width docked sheet',
      (tester) async {
    await pumpCard(tester, const Size(360, 780));

    // A docked sheet would span the full width AND touch the bottom edge.
    final rect = tester.getRect(find.byType(ResultCard));
    expect(rect.width, lessThan(360), reason: 'card must not span the width');
    expect(rect.left, greaterThan(0));
    expect(rect.right, lessThan(360));
    expect(rect.bottom, lessThan(780), reason: 'card must not touch the bottom');
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone: the card stays inside the viewport', (tester) async {
    await pumpCard(tester, const Size(360, 780));
    final rect = tester.getRect(find.byType(ResultCard));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(360));
    expect(rect.bottom, lessThanOrEqualTo(780));
  });

  testWidgets('phone: the card is roughly centred, not clamped to a corner',
      (tester) async {
    await pumpCard(tester, const Size(360, 780));
    final rect = tester.getRect(find.byType(ResultCard));
    // Centred horizontally with a small tolerance for the clamp margin.
    expect((rect.center.dx - 180).abs(), lessThan(12));
  });

  testWidgets('phone: dragging the title bar moves the card', (tester) async {
    // 400dp wide: a 360dp card leaves only 12dp of horizontal travel, which
    // cannot demonstrate a drag. 400dp is still a phone layout.
    await pumpCard(tester, const Size(400, 780));
    final before = tester.getRect(find.byType(ResultCard));

    // Drag by the title bar (the gesture handle). The card starts clamped to
    // the top-left margin on a phone, so move it DOWN-RIGHT (where there is
    // room) to observe the change.
    await tester.drag(
      find.byKey(const Key('card-drag-handle')),
      const Offset(30, 40),
    );
    await tester.pumpAndSettle();

    final after = tester.getRect(find.byType(ResultCard));
    expect(after.top, greaterThan(before.top),
        reason: 'card should follow the drag down');
    // Horizontal travel is tiny on a phone-sized viewport (the card nearly
    // fills the width), so only the vertical axis is asserted strictly.
    expect(after.left, greaterThanOrEqualTo(before.left));
    // It must stay fully on screen after the drag.
    expect(after.left, greaterThanOrEqualTo(0));
    expect(after.top, greaterThanOrEqualTo(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop: the card keeps its resizable size and grip',
      (tester) async {
    tester.view.physicalSize = const Size(2560, 1600);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final container = ProviderScope.containerOf(context);
                final n = container.read(aiProvider.notifier);
                // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                n.state = n.state.copyWith(cardVisible: true);
              });
              return const Stack(children: [ResultCard()]);
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Desktop keeps the resize grip (phones suppress it: the card is clamped
    // to the viewport anyway).
    expect(find.byKey(const Key('card-resize-handle')), findsOneWidget);
    final rect = tester.getRect(find.byType(ResultCard));
    expect(rect.width, greaterThan(360));
    expect(rect.width, lessThanOrEqualTo(Golden.maxCardWidth + 400));
  });
}
