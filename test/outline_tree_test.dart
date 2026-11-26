import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/reader/widgets/sidebars/outline_tree.dart';
import 'package:rbwa/src/rust/pdf/types.dart';

import 'helpers/fake_reader_repo.dart';
import 'helpers/fake_settings.dart';
import 'helpers/widget_harness.dart';

/// Two-level outline: Chapter 1 with two sections, used to observe whether
/// the child rows are rendered by default.
const _outline = [
  OutlineEntry(
    key: 'pdf:0',
    title: 'Chapter 1',
    page: 0,
    children: [
      OutlineEntry(key: 'pdf:0.0', title: 'Section 1.1', page: 0, children: []),
      OutlineEntry(key: 'pdf:0.1', title: 'Section 1.2', page: 0, children: []),
    ],
  ),
];

Widget _tree({required bool expandAll}) => ProviderScope(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(
            FakeReaderRepository(outlineEntries: _outline)),
        settingsRepositoryProvider.overrideWithValue(
            FakeSettings({'outline_expand_all': expandAll ? 'true' : 'false'})),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 240,
              height: 600,
              child: OutlineTree(onJump: _noop),
            ),
          ),
        ),
      ),
    );

void _noop(int page) {}

void main() {
  testWidgets('collapsed by default: only top-level chapters show',
      (tester) async {
    await tester.pumpWidget(_tree(expandAll: false));
    await tester.pumpAndSettle();

    expect(find.text('Chapter 1'), findsOneWidget);
    // Sections stay hidden until the user expands the chapter.
    expect(find.text('Section 1.1'), findsNothing);
    expect(find.text('Section 1.2'), findsNothing);

    // Tapping the chevron reveals them.
    await tester.tap(find.byIcon(LucideIcons.chevronRight));
    await tester.pumpAndSettle();
    expect(find.text('Section 1.1'), findsOneWidget);
    expect(find.text('Section 1.2'), findsOneWidget);
  });

  testWidgets('expand-all setting opens every level up front', (tester) async {
    await tester.pumpWidget(_tree(expandAll: true));
    await tester.pumpAndSettle();

    expect(find.text('Chapter 1'), findsOneWidget);
    expect(find.text('Section 1.1'), findsOneWidget);
    expect(find.text('Section 1.2'), findsOneWidget);
    // Fully expanded: the chapter shows the collapse chevron.
    expect(find.byIcon(LucideIcons.chevronDown), findsOneWidget);
  });

  // -------------------------------------------------------------------
  // Outline editing (T3). The merge logic is unit-tested in Rust; these
  // cover the UI -> repository wiring: which node key is addressed, and
  // whether the reset action reaches the book-wide command.
  // -------------------------------------------------------------------

  testWidgets('context menu hides the node it was opened on',
      (tester) async {
    final fake = FakeReaderRepository(outlineEntries: _outline);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(fake),
        settingsRepositoryProvider.overrideWithValue(
            FakeSettings({'outline_expand_all': 'false'})),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 600,
            child: OutlineTree(onJump: _noop),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Desktop opens the menu on right-click (touch uses long-press).
    final row = tester.getCenter(find.text('Chapter 1'));
    final gesture = await tester.startGesture(
      row,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('隐藏此项'), findsOneWidget);
    await tester.tap(find.text('隐藏此项'));
    await tester.pumpAndSettle();

    expect(fake.outlineSaves, hasLength(1));
    expect(fake.outlineSaves.single['entryKey'], 'pdf:0');
    expect(fake.outlineSaves.single['hidden'], isTrue);
    // A rename/hide must not touch book-wide state.
    expect(fake.outlineResets, 0);
  });

  testWidgets('header menu restores the original outline', (tester) async {
    final fake = FakeReaderRepository(outlineEntries: _outline);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(fake),
        settingsRepositoryProvider.overrideWithValue(
            FakeSettings({'outline_expand_all': 'false'})),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 600,
            child: OutlineTree(onJump: _noop),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(LucideIcons.ellipsisVertical));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复原始目录'));
    await tester.pumpAndSettle();

    expect(fake.outlineResets, 1);
    // Reset is book-wide: it must not go through the per-node save.
    expect(fake.outlineSaves, isEmpty);
  });
}
