import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/reader/widgets/sidebars/outline_tree.dart';
import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/pdf/types.dart';

import 'helpers/widget_harness.dart';

/// Two-level outline: Chapter 1 with two sections, used to observe whether
/// the child rows are rendered by default.
class _FakeRepo extends ReaderRepository {
  @override
  Future<rust.OutlineResult> getOutline(int bookId) async => rust.OutlineResult(
        entries: const [
          OutlineEntry(
            title: 'Chapter 1',
            page: 0,
            children: [
              OutlineEntry(title: 'Section 1.1', page: 0, children: []),
              OutlineEntry(title: 'Section 1.2', page: 0, children: []),
            ],
          ),
        ],
        error: null,
      );
}

/// Settings KV stub: returns the value configured for the outline key.
class _FakeSettings extends SettingsRepository {
  _FakeSettings(this._value);
  final String? _value;

  @override
  Future<String?> getSetting(String key) async =>
      key == 'outline_expand_all' ? _value : null;

  @override
  Future<int> setSetting(String key, String value) async => 1;
}

Widget _tree({required bool expandAll}) => ProviderScope(
      overrides: [
        defaultViewer(),
        readerRepositoryProvider.overrideWithValue(_FakeRepo()),
        settingsRepositoryProvider
            .overrideWithValue(_FakeSettings(expandAll ? 'true' : 'false')),
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
    await tester.tap(find.byIcon(Icons.chevron_right));
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
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });
}
