import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/library/providers/library_selection_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  LibrarySelectionState state() => container.read(librarySelectionProvider);

  test('begin selects one book and activates the mode', () {
    container.read(librarySelectionProvider.notifier).begin(7);
    expect(state().active, isTrue);
    expect(state().ids, {7});
    expect(state().count, 1);
  });

  test('toggle adds and removes; emptying the set exits the mode', () {
    final n = container.read(librarySelectionProvider.notifier);
    n.begin(1);
    n.toggle(2);
    expect(state().ids, {1, 2});

    n.toggle(1);
    expect(state().ids, {2});
    expect(state().active, isTrue);

    n.toggle(2);
    expect(state().ids, isEmpty);
    expect(state().active, isFalse);
  });

  test('retain drops ids that no longer exist', () {
    final n = container.read(librarySelectionProvider.notifier);
    n.begin(1);
    n.toggle(2);
    n.toggle(3);

    n.retain({1, 3, 9});
    expect(state().ids, {1, 3});

    n.retain({9});
    expect(state().active, isFalse);
  });

  test('clear exits the mode entirely', () {
    final n = container.read(librarySelectionProvider.notifier);
    n.begin(5);
    n.clear();
    expect(state().active, isFalse);
    expect(state().ids, isEmpty);
  });

  test('state uses value equality (no rebuild loop in the grid)', () {
    const a = LibrarySelectionState(active: true, ids: {1, 2});
    const b = LibrarySelectionState(active: true, ids: {2, 1});
    expect(a, b);
    expect(a.hashCode, b.hashCode);

    const c = LibrarySelectionState(active: true, ids: {1});
    expect(a, isNot(c));

    // Inactive vs active with the same ids still differ.
    const d = LibrarySelectionState(active: false, ids: {1, 2});
    expect(a, isNot(d));
  });

  test('retain is a no-op when every id still exists', () {
    final n = container.read(librarySelectionProvider.notifier);
    n.begin(1);
    n.toggle(2);

    var notifications = 0;
    final sub = container.listen(
      librarySelectionProvider,
      (_, _) => notifications++,
    );
    addTearDown(sub.close);

    // The grid calls retain from a post-frame callback on every build: an
    // unchanged selection must not publish (that made the library rebuild
    // once per frame while multi-select was active).
    n.retain({1, 2, 3});
    expect(notifications, 0);
    expect(state().ids, {1, 2});

    n.retain({1});
    expect(notifications, 1);
    expect(state().ids, {1});
  });
}
