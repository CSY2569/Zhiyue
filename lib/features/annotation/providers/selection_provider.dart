import 'dart:ui' show Offset, Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/models/selection.dart';

/// UI state for the selection-driven floating elements (FEATURES 4.2 / 8.4):
/// the active selection, the floating toolbar, the note popup, and the note
/// composer. All positions are *global screen coordinates* so the Overlay
/// children can position themselves directly.
class SelectionUiState {
  const SelectionUiState({
    this.selection,
    this.toolbarAnchor,
    this.toolbarPos,
    this.noteTargetId,
    this.composerPos,
  });

  /// Active character-range selection (null = none).
  final Selection? selection;

  /// Global rect of the selection's first line; the toolbar auto-positions
  /// above it (FEATURES 4.2.1). Null while dragging (toolbar hidden).
  final Rect? toolbarAnchor;

  /// User-dragged toolbar position (FEATURES 4.2.2 / 8.4); null = auto.
  final Offset? toolbarPos;

  /// Id of the annotation whose note popup is open (FEATURES 4.4.2).
  final int? noteTargetId;

  /// Global position of the note composer (FEATURES 4.4.1); null = closed.
  final Offset? composerPos;

  SelectionUiState copyWith({
    Selection? selection,
    Rect? toolbarAnchor,
    bool clearAnchor = false,
    Offset? toolbarPos,
    bool clearToolbarPos = false,
    int? noteTargetId,
    bool clearNote = false,
    Offset? composerPos,
    bool clearComposer = false,
  }) {
    return SelectionUiState(
      selection: selection ?? this.selection,
      toolbarAnchor: clearAnchor ? null : (toolbarAnchor ?? this.toolbarAnchor),
      toolbarPos: clearToolbarPos ? null : (toolbarPos ?? this.toolbarPos),
      noteTargetId: clearNote ? null : (noteTargetId ?? this.noteTargetId),
      composerPos: clearComposer ? null : (composerPos ?? this.composerPos),
    );
  }
}

/// Manages selection + floating-element state. Selection drives the toolbar
/// (shown only after the drag ends, anchored above the selection); the note
/// popup/composer are opened from the toolbar / highlight taps.
class SelectionNotifier extends Notifier<SelectionUiState> {
  @override
  SelectionUiState build() => const SelectionUiState();

  /// Live update while dragging: selection preview only, toolbar hidden.
  void updateSelection(Selection sel) {
    state = state.copyWith(
      selection: sel,
      clearAnchor: true,
      clearToolbarPos: true,
    );
  }

  /// Drag finished: anchor the toolbar above the selection (FEATURES 4.2.1).
  void commitSelection(Selection sel, Rect anchor) {
    state = state.copyWith(selection: sel, toolbarAnchor: anchor);
  }

  /// Drop everything (Esc / tapping whitespace / scrolling, FEATURES 4.1.3 /
  /// 8.6).
  void clear() => state = const SelectionUiState();

  /// User dragged the toolbar to a new position (FEATURES 4.2.2).
  void moveToolbar(Offset pos) => state = state.copyWith(toolbarPos: pos);

  /// Open the note popup for annotation [id] (FEATURES 4.4.2). Clears the
  /// selection so the popup is not fighting the toolbar.
  void openNote(int id) => state = SelectionUiState(noteTargetId: id);

  void closeNote() => state = state.copyWith(clearNote: true);

  /// Open the note composer at [pos] (FEATURES 4.4.1). The selection stays so
  /// the composer knows what text/rects to attach the note to.
  void openComposer(Offset pos) => state = state.copyWith(composerPos: pos);

  void closeComposer() => state = state.copyWith(clearComposer: true);
}

/// Selection + floating-element UI state.
final selectionProvider =
    NotifierProvider<SelectionNotifier, SelectionUiState>(SelectionNotifier.new);
