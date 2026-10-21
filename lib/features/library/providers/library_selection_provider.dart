import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Multi-select state for the library grid.
///
/// Touch-first bulk management: long-press a card enters selection mode, taps
/// then toggle cards instead of opening them, and a bottom action bar offers
/// favorite / category / delete for the whole selection. Desktop keeps the
/// context menu and never enters this mode implicitly.
class LibrarySelectionState {
  const LibrarySelectionState({this.active = false, this.ids = const {}});

  /// Selection mode is on (cards show check marks).
  final bool active;

  /// Selected book ids.
  final Set<int> ids;

  int get count => ids.length;

  bool contains(int id) => ids.contains(id);

  LibrarySelectionState copyWith({bool? active, Set<int>? ids}) =>
      LibrarySelectionState(
        active: active ?? this.active,
        ids: ids ?? this.ids,
      );

  /// Value equality matters here: the library grid calls `retain` from a
  /// post-frame callback, and Riverpod only suppresses a notification when the
  /// new state compares equal. Without this, every rebuild published a fresh
  /// state object, re-triggering the rebuild -- an endless frame loop while
  /// multi-select was active.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibrarySelectionState &&
          other.active == active &&
          setEquals(other.ids, ids);

  @override
  int get hashCode => Object.hash(active, Object.hashAllUnordered(ids));
}

class LibrarySelectionNotifier extends Notifier<LibrarySelectionState> {
  @override
  LibrarySelectionState build() => const LibrarySelectionState();

  void begin(int id) {
    state = LibrarySelectionState(active: true, ids: {id});
  }

  void toggle(int id) {
    final ids = {...state.ids};
    if (!ids.remove(id)) ids.add(id);
    if (ids.isEmpty) {
      state = const LibrarySelectionState();
    } else {
      state = LibrarySelectionState(active: true, ids: ids);
    }
  }

  void clear() => state = const LibrarySelectionState();

  /// Drops ids that no longer exist (e.g. after a delete refresh). A no-op
  /// when nothing was dropped, so calling it from a build callback cannot
  /// notify listeners for an unchanged selection.
  void retain(Set<int> existing) {
    if (!state.active) return;
    final kept = state.ids.intersection(existing);
    if (kept.length == state.ids.length) return;
    state = kept.isEmpty
        ? const LibrarySelectionState()
        : LibrarySelectionState(active: true, ids: kept);
  }
}

final librarySelectionProvider =
    NotifierProvider<LibrarySelectionNotifier, LibrarySelectionState>(
  LibrarySelectionNotifier.new,
);
