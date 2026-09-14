import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/widgets/panel_resize_handle.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_panel_side.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';
import 'package:rbwa/features/annotation/export_actions.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/annotation/widgets/mark_toolbar.dart';
import 'package:rbwa/features/annotation/widgets/note_composer.dart';
import 'package:rbwa/features/annotation/widgets/note_popup.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_queue_provider.dart';
import 'package:rbwa/features/bilingual/widgets/translated_pane.dart'
    show TranslatedColumn;
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart';
import 'package:rbwa/features/reader/widgets/reader_toolbar.dart';
import 'package:rbwa/features/reader/widgets/sidebars/notes_rail.dart';
import 'package:rbwa/features/reader/widgets/sidebars/outline_tree.dart';
import 'package:rbwa/features/reader/widgets/sidebars/thumbnail_rail.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/progress.dart';

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
  late final ProviderSubscription _aiPanelSub;
  late final ProviderSubscription _queueSub;

  /// The AI panel was opened before or after the left sidebar; when panels
  /// squeeze the reading area below its minimum, the EARLIER-opened one is
  /// clamped first (plan §1 v4.2 后开启者优先 -- the later keeps its width).
  /// The 对照 view is NOT here: it lives inside the content area as a 50/50
  /// split and needs no clamping.
  final List<String> _rightOrder = [];
  bool _sidebarCollapseNotified = false;
  int? _lastQueuedBookId;

  @override
  void initState() {
    super.initState();
    // Open the book on first build. Use post-frame to avoid provider
    // mutation during the build phase. A pending full-text search jump
    // (M6, 3.5.2) overrides the restored progress position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final jump = ref.read(searchHitProvider);
      if (jump != null && jump.bookId == widget.bookId) {
        ref
            .read(viewerProvider.notifier)
            .openBook(widget.bookId, jumpPage: jump.page + 1);
      } else {
        ref.read(viewerProvider.notifier).openBook(widget.bookId);
      }
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

    // Track the open order of the AI panel vs the left sidebar (plan §1 v4.2).
    _aiPanelSub = ref.listenManual(
      aiProvider.select((s) => s.aiPanelOpen),
      (prev, next) {
        if (next && !(prev ?? false)) _rightOrder.add('ai');
        if (!next) _rightOrder.remove('ai');
      },
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

    // Bilingual reading queue (plan §10): 随进度 mode enqueues the visible
    // page + the next two on every page turn; a re-opened book resumes an
    // unfinished whole-book run per the background setting (plan §9).
    _queueSub = ref.listenManual(
      viewerProvider.select((s) => (s.book?.id, s.mode, s.currentPage)),
      (prev, next) {
        final bookId = next.$1;
        if (bookId == null) return;
        final queue = ref.read(translationQueueProvider.notifier);
        final newBook = _lastQueuedBookId != bookId;
        _lastQueuedBookId = bookId;
        if (newBook) {
          queue.resumeIfNeeded(bookId, ref.read(viewerProvider).pageCount);
        }
        if (prev != next) {
          final List<int> visible = next.$2 == ViewMode.single
              ? [next.$3]
              : [next.$3, next.$3 + 1];
          queue.onVisiblePages(bookId, visible);
        }
      },
    );
  }

  void _setVisible(OverlayPortalController c, bool show) {
    if (show && !c.isShowing) c.show();
    if (!show && c.isShowing) c.hide();
  }

  /// Clamps the AI panel so the reading area keeps at least
  /// [PanelLayout.minContentWidth] logical pixels (plan §1 v4.2); if even its
  /// minimum does not fit, the left sidebar is collapsed with a one-time hint.
  /// The 对照 view needs no clamping: it is a 50/50 split INSIDE the content
  /// area, so the original always keeps half of whatever is available.
  ///
  /// Runs in a post-frame callback: the widths live in [PanelLayoutNotifier],
  /// and mutating a provider during build is not allowed.
  void _enforceContentMinimum(
    double available, {
    required bool aiOpen,
    required bool sidebarOpen,
    required double sidebarWidth,
    required BuildContext context,
  }) {
    if (available <= 0) return;
    final layout = ref.read(panelLayoutProvider);
    final aiW = aiOpen ? layout.aiPanelWidth : 0.0;
    final content = available - sidebarWidth - aiW;
    if (content >= PanelLayout.minContentWidth) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final notifier = ref.read(panelLayoutProvider.notifier);
      var deficit = PanelLayout.minContentWidth - content;

      // The later-opened panel keeps its width; reduce earlier ones first.
      for (final which in _rightOrder.reversed) {
        if (deficit <= 0) break;
        if (which == 'ai' && aiOpen) {
          final cur = ref.read(panelLayoutProvider);
          final next = (cur.aiPanelWidth - deficit)
              .clamp(PanelLayout.minAiPanelWidth, cur.aiPanelWidth);
          deficit -= cur.aiPanelWidth - next;
          notifier.clampAiPanel(next);
        }
      }
      if (deficit != PanelLayout.minContentWidth - content) notifier.commit();

      // Still not enough room -> collapse the left sidebar (once).
      if (deficit > 0 && sidebarOpen) {
        if (!_sidebarCollapseNotified) {
          _sidebarCollapseNotified = true;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('阅读区空间不足，已自动收起左侧栏')),
          );
        }
        final side = ref.read(viewerProvider).openSidebar;
        if (side != null) {
          ref.read(viewerProvider.notifier).toggleSidebar(side);
        }
      }
    });
  }

  @override
  void dispose() {
    _selectionSub.close();
    _viewerSub.close();
    _aiSub.close();
    _aiPanelSub.close();
    _queueSub.close();
    // NOTE: cannot call ref.read() here -- Riverpod forbids using `ref` after
    // the widget is disposed. The ViewerNotifier's own dispose() cancels the
    // debounce timer; closing the pdfium document happens lazily when the
    // next book is opened (or on app exit), so no explicit close is needed.
    super.dispose();
  }

  /// Global shortcuts (FEATURES 8.6 / 8.x): Esc clears the selection and
  /// closes floating editors; Ctrl+S exports annotations (last format);
  /// Ctrl+Z / Ctrl+Shift+Z undo / redo image-layer mark edits (5.7). The AI
  /// result card is NOT closed here -- it stays open until the user clicks
  /// its close button.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      ref.read(selectionProvider.notifier).clear();
      // Esc also dismisses the full-text search hit highlight (M6, 3.5.3).
      ref.read(searchHitProvider.notifier).state = null;
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyS) {
        exportAnnotations(context, ref);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        final notifier = ref.read(imageMarkProvider.notifier);
        if (HardwareKeyboard.instance.isShiftPressed) {
          notifier.redo();
        } else {
          notifier.undo();
        }
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(viewerProvider);
    final aiOpen = ref.watch(aiProvider.select((s) => s.aiPanelOpen));
    final translateOpen =
        ref.watch(translationPaneProvider.select((s) => s.open));
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
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // Keep the reading area usable when several panels are
                      // open (plan §1 v4.2): clamp the earlier-opened panel
                      // first, then any remaining panel.
                      _enforceContentMinimum(
                        constraints.maxWidth,
                        aiOpen: aiOpen,
                        sidebarOpen: state.openSidebar != null,
                        sidebarWidth:
                            state.openSidebar == null
                                ? 0
                                : ref
                                    .read(panelLayoutProvider)
                                    .widthFor(state.openSidebar!),
                        context: context,
                      );
                      return Row(
                        children: [
                          if (state.openSidebar != null) ...[
                            _buildSidebar(state),
                            // Drag the sidebar's right edge to resize it
                            // (FEATURES 3.4.4); the content Expanded reflows.
                            PanelResizeHandle(
                              onResize: (dx) => ref
                                  .read(panelLayoutProvider.notifier)
                                  .resizeSidebar(state.openSidebar!, dx),
                              onResizeEnd: () => ref
                                  .read(panelLayoutProvider.notifier)
                                  .commit(),
                            ),
                          ],
                          Expanded(
                            child: translateOpen
                                ? _buildSplitContent(context, state)
                                : _buildContent(context, state),
                          ),
                          if (aiOpen) ...[
                            // The AI panel stays a resizable side panel;
                            // its handle is right-aligned, so a drag left
                            // (negative dx) widens it.
                            PanelResizeHandle(
                              onResize: (dx) => ref
                                  .read(panelLayoutProvider.notifier)
                                  .resizeAiPanel(-dx),
                              onResizeEnd: () => ref
                                  .read(panelLayoutProvider.notifier)
                                  .commit(),
                            ),
                            AiPanelSide(
                              bookId: book?.id,
                              bookTitle: book?.title,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
            // Floating selection UI (rendered above everything, in the
            // app-level Overlay so they are never clipped). The scan prompt
            // (FEATURES 7.1.2) lives inside each page instead: it anchors to
            // the page's top-left corner and scrolls with it.
            // Mark tool bar (FEATURES §5): floats above the reading area
            // while a mark tool is armed.
            Positioned(
              top: 8,
              left: 0,
              right: 0,
              child: Center(child: MarkToolBar()),
            ),
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

  /// 对照 view (plan §1 v4.2): the reading area splits 50/50 -- the original
  /// page on the left, its translation on the right, no drag handle (like the
  /// double-page mode). The translation column follows the original's current
  /// page; the original keeps every interaction (zoom, selection, marks).
  Widget _buildSplitContent(BuildContext context, ViewerState state) {
    // Double-page spread: both halves share the reading background, the
    // pages are separated by the same gutter the double views use.
    return Row(
      children: [
        Expanded(child: _buildContent(context, state)),
        const SizedBox(width: 12),
        const Expanded(child: TranslatedColumn()),
      ],
    );
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
