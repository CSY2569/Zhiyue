import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/app.dart';
import 'helpers/widget_harness.dart';
import 'package:rbwa/features/shell/app_title_bar.dart';
import 'package:rbwa/router/app_router.dart';

void main() {
  testWidgets('title bar reacts to route changes', (tester) async {
    // viewerProvider is watched by the shell; provide a stable fake so no
    // Rust calls happen during navigation.
    await tester.pumpWidget(ProviderScope(
      overrides: [
        seededViewer(const ViewerState(loading: false, error: null)),
      ],
      child: const RbwaApp(),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // On /library: app title, no back button.
    expect(find.byType(AppTitleBar), findsOneWidget);
    expect(find.text('RBWA'), findsOneWidget);
    expect(find.byTooltip('返回书库'), findsNothing);
    expect(tester.takeException(), isNull,
        reason: 'library: ${tester.takeException()}');

    // Navigate to the reader: back button appears, title switches.
    appRouter.go('/reader/1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('返回书库'), findsOneWidget,
        reason: 'back button should appear in reader');
    expect(find.text('阅读器'), findsOneWidget,
        reason: 'reader title fallback should show');
    expect(tester.takeException(), isNull,
        reason: 'reader: ${tester.takeException()}');

    // Back to library: button disappears.
    appRouter.go('/library');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('返回书库'), findsNothing);
    expect(find.text('RBWA'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'back-to-library: ${tester.takeException()}');
  });
}
