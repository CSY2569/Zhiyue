import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_panel_side.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';
import 'package:rbwa/features/annotation/export_actions.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/annotation/widgets/note_composer.dart';
import 'package:rbwa/features/annotation/widgets/note_popup.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart';
import 'package:rbwa/features/reader/widgets/reader_toolbar.dart';
import 'package:rbwa/features/reader/widgets/sidebars/notes_rail.dart';
import 'package:rbwa/features/reader/widgets/sidebars/outline_tree.dart';
import 'package:rbwa/features/reader/widgets/sidebars/thumbnail_rail.dart';

/// Reader page (FEATURES §3 + §4 + §6).
///
/// Hosts the [ReaderToolbar], the optional sidebars (thumbnails / outline /
/// annotations), the [PdfPageScroll] rendering area, the AI side panel, and
/// the floating selection UI (toolbar / note composer / note popup) plus the
/// AI result card, all driven by providers. On init it opens the book via the
/// [ViewerNotifier] and restores saved progress.
class ReaderPage extends ConsumerStatefulWidget {
  const ReaderPage({super.key, required this.bookId});

  final int bookId;

  @override
  ConsumerState<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<ReaderPage> {
  final _toolbarController = OverlayPortalController();
  final _composerController = OverlayPortalController();
  final _noteController = OverlayPortalController();
  final _aiCardController = OverlayPortalController();
  late final ProviderSubscription _selectionSub;
  late final ProviderSubscription _viewerSub;
  late final ProviderSubscription _aiSub;

  @override
  void initState() {
    super.initState();
    // Open the book on first build. Use post-frame to avoid provider
    // mutation during the build phase.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(viewerProvider.notifier).openBook(widget.bookId);
    });

    // Selection state drives the floating overlays (FEATURES 4.2/4.4).
    _selectionSub = ref.listenManual(selectionProvider, (prev, next) {
      _setVisible(
          _toolbarController,
          next.selection != null &&
              next.toolbarAnchor != null &&
              next.composerPos == null);
      _setVisible(_composerController, next.composerPos != null);
      _setVisible(_noteController, next.noteTargetId != null);
    });

    // The AI result card shows from action start until the user closes or
    // expands it (FEATURES 6.4.1); it survives stream completion.
    _aiSub = ref.listenManual(
      aiProvider.select((s) => s.cardVisible),
      (prev, next) => _setVisible(_aiCardController, next),
    );

    // Book / zoom / mode / page changes invalidate the current selection
    // (its screen anchor no longer matches the content). A book change also
    // follows the per-book conversation window in the AI panel (6.5.4).
    _viewerSub = ref.listenManual(
      viewerProvider.select(
          (s) => (s.book?.id, s.zoom, s.mode, s.currentPage)),
      (prev, next) {
        if (prev != next) {
          ref.read(selectionProvider.notifier).clear();
          if (prev.$1 != next.$1) {
            ref.read(aiProvider.notifier).selectWindowForBook(next.$1);
          }
        }
      },
    );
  }

  void _setVisible(OverlayPortalController c, bool show) {
    if (show && !c.isShowing) c.show();
    if (!show && c.isShowing) c.hide();
  }

  @override
  void dispose() {
    _selectionSub.close();
    _viewerSub.close();
    _aiSub.close();
    // NOTE: cannot call ref.read() here -- Riverpod forbids using `ref` after
    // the widget is disposed. The ViewerNotifier's own dispose() cancels the
    // debounce timer; closing the pdfium document happens lazily when the
    // next book is opened (or on app exit), so no explicit close is needed.
    super.dispose();
  }

  /// Global shortcuts (FEATURES 8.6 / 8.x): Esc clears the selection and
  /// closes floating editors; Ctrl+S exports
  /// annotations (last format). The AI result card is NOT closed here -- it
  /// stays open until the user clicks its close button.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(selectionProvider.notifier).clear();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyS) {
      exportAnnotations(context, ref);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(viewerProvider);
    final aiOpen = ref.watch(aiProvider.select((s) => s.aiPanelOpen));
    // Book snapshot for the AI widgets (per-book conversation windows,
    // 6.5.4); the AI notifier itself never reads the viewer state.
    final book = state.book;

    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (state.error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text(state.error!, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/library'),
                child: const Text('返回书库'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKeyEvent,
        child: Stack(
          children: [
            Column(
              children: [
                const ReaderToolbar(),
                Expanded(
                  child: Row(
                    children: [
                      if (state.openSidebar != null) _buildSidebar(state),
                      Expanded(child: _buildContent(context, state)),
                      if (aiOpen)
                        AiPanelSide(
                          bookId: book?.id,
                          bookTitle: book?.title,
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // Floating selection UI (rendered above everything, in the
            // app-level Overlay so they are never clipped).
            OverlayPortal(
              controller: _toolbarController,
              overlayChildBuilder: (_) => FloatingToolbar(
                bookId: book?.id,
                bookTitle: book?.title,
              ),
            ),
            OverlayPortal(
              controller: _composerController,
              overlayChildBuilder: (_) => const NoteComposer(),
            ),
            OverlayPortal(
              controller: _noteController,
              overlayChildBuilder: (_) => const NotePopup(),
            ),
            OverlayPortal(
              controller: _aiCardController,
              overlayChildBuilder: (_) => ResultCard(
                bookId: book?.id,
                bookTitle: book?.title,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(ViewerState state) {
    switch (state.openSidebar!) {
      case SidebarType.thumbnails:
        return ThumbnailRail(
          onJump: (page) => _jumpToPage(page + 1), // 0-indexed -> 1-indexed
        );
      case SidebarType.outline:
        return OutlineTree(
          onJump: (page) => _jumpToPage(page + 1),
        );
      case SidebarType.annotations:
        return NotesRail(
          onJump: (page) => _jumpToPage(page + 1),
        );
    }
  }

  Widget _buildContent(BuildContext context, ViewerState state) {
    // Any scroll (page flips included) invalidates the selection: its
    // floating toolbar anchor no longer matches the content on screen.
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        final sel = ref.read(selectionProvider);
        if (sel.selection != null || sel.toolbarAnchor != null) {
          ref.read(selectionProvider.notifier).clear();
        }
        return false;
      },
      child: Listener(
        // Ctrl+scroll zoom (FEATURES 3.2.2 / 8.7).
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent &&
              HardwareKeyboard.instance.isControlPressed) {
            final delta = signal.scrollDelta.dy > 0 ? -0.1 : 0.1;
            ref.read(viewerProvider.notifier).setZoom(state.zoom + delta);
          }
        },
        child: const PdfPageScroll(),
      ),
    );
  }

  void _jumpToPage(int page) {
    ref.read(viewerProvider.notifier).setPage(page);
    // The PdfPageScroll reads currentPage from state and scrolls.
  }
}
