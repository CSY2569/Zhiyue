import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rbwa/core/navigation.dart';

void main() {
  testWidgets('navigateBack pops a pushed route', (tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(path: '/a', builder: (_, _) => const Text('A')),
        GoRoute(path: '/b', builder: (_, _) => const Text('B')),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    router.push('/b');
    await tester.pumpAndSettle();
    expect(find.text('B'), findsOneWidget);
    expect(router.canPop(), isTrue);

    navigateBack(router);
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);
    expect(router.canPop(), isFalse);
  });

  testWidgets('navigateBack falls back to the library at the root',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/a',
      routes: [
        GoRoute(path: '/a', builder: (_, _) => const Text('A')),
        GoRoute(path: '/library', builder: (_, _) => const Text('LIB')),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    expect(router.canPop(), isFalse);

    navigateBack(router);
    await tester.pumpAndSettle();
    expect(find.text('LIB'), findsOneWidget);
  });
}
