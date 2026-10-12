import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/progress.dart' show ViewMode;

/// Open/closed state of the bilingual-reading 对照 view.
///
/// No longer a side panel: when open, the READING AREA itself splits 50/50
/// into original (left) + translation (right), like the double-page mode.
/// [modeBefore] remembers the view mode the reader had before opening --
/// 对照 pairs one original page with its translation, so opening forces the
/// single-page view, and closing restores what the user had.
///
/// The per-page translation state of the retired built-in pipeline is gone;
/// the right column is driven by the bundled RetainPDF engine (staged).
class TranslationPaneState {
  const TranslationPaneState({
    this.open = false,
    this.modeBefore,
  });

  final bool open;

  /// View mode to restore on close (null = the reader was already single-page).
  final ViewMode? modeBefore;
}

class TranslationPaneNotifier extends Notifier<TranslationPaneState> {
  @override
  TranslationPaneState build() => const TranslationPaneState();

  void toggle() {
    if (state.open) {
      close();
      return;
    }
    final viewer = ref.read(viewerProvider);
    // Remember a non-single mode so close() can restore it.
    final modeBefore =
        viewer.mode != ViewMode.single ? viewer.mode : state.modeBefore;
    if (viewer.mode != ViewMode.single) {
      ref.read(viewerProvider.notifier).setMode(ViewMode.single);
    }
    state = TranslationPaneState(open: true, modeBefore: modeBefore);
  }

  void close() {
    final restore = state.modeBefore;
    if (restore != null) {
      ref.read(viewerProvider.notifier).setMode(restore);
    }
    state = TranslationPaneState(open: false);
  }
}

final translationPaneProvider =
    NotifierProvider<TranslationPaneNotifier, TranslationPaneState>(
        TranslationPaneNotifier.new);