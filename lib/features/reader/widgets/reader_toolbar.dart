import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/text_input_dialog.dart';
import 'package:rbwa/core/widgets/toolbar_icon_button.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart'
    show MarkTool, markToolProvider;
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/screenshot/screenshot_provider.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Reader toolbar (FEATURES 3.1.4, 3.2.1, 3.3.1, 3.4, 6.6/7.2).
///
/// Left to right: sidebar toggles (thumbnails / outline / annotations), the
/// view-mode selector (single / double-scroll / double-page in one popup),
/// zoom controls, page navigation, then the free screenshot button and the
/// AI panel toggle. All actions delegate to the [ViewerNotifier] /
/// [AiNotifier] / [ScreenshotNotifier].
class ReaderToolbar extends ConsumerWidget implements PreferredSizeWidget {
  const ReaderToolbar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(48);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(viewerProvider);
    final notifier = ref.read(viewerProvider.notifier);
    final theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          // Sidebar toggles (3.4) -- leftmost.
          ToolbarIconButton(
            icon: LucideIcons.list,
            tooltip: '缩略图',
            active: state.openSidebar == SidebarType.thumbnails,
            onTap: () => notifier.toggleSidebar(SidebarType.thumbnails),
          ),
          ToolbarIconButton(
            icon: LucideIcons.network,
            tooltip: '目录',
            active: state.openSidebar == SidebarType.outline,
            onTap: () => notifier.toggleSidebar(SidebarType.outline),
          ),
          ToolbarIconButton(
            icon: LucideIcons.bookmark,
            tooltip: '标注',
            active: state.openSidebar == SidebarType.annotations,
            onTap: () => notifier.toggleSidebar(SidebarType.annotations),
          ),
          // 对照阅读 (bilingual reading, M7): double-page-style spread --
          // the reading area splits into original (left) + translation
          // (right) at the same display size. The spread actions (export /
          // whole-book) return together with further engine integrations.
          ToolbarIconButton(
            icon: LucideIcons.languages,
            tooltip: '对照阅读',
            active: ref.watch(translationPaneProvider.select((s) => s.open)),
            onTap: () => ref.read(translationPaneProvider.notifier).toggle(),
          ),
          const VDivider(),
          // View mode selector (3.1): one popup for the three modes.
          const _ModeSelector(),
          const VDivider(),
          // Zoom (3.2.1)
          IconButton(
            icon: const Icon(LucideIcons.zoomOut, size: 20),
            tooltip: '缩小',
            onPressed: notifier.zoomOut,
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(state.zoom * 100).round()}%',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.zoomIn, size: 20),
            tooltip: '放大',
            onPressed: notifier.zoomIn,
          ),
          IconButton(
            icon: const Icon(LucideIcons.rotateCcw, size: 20),
            tooltip: '恢复缩放',
            onPressed: notifier.resetZoom,
          ),
          const VDivider(),
          // Paging (3.3.1)
          IconButton(
            icon: const Icon(LucideIcons.chevronLeft, size: 20),
            tooltip: '上一页',
            onPressed: state.currentPage > 1 ? notifier.prevPage : null,
          ),
          GestureDetector(
            onTap: () => _showPageJumpDialog(context, ref),
            child: Text(
              '${state.currentPage} / ${state.pageCount}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            icon: const Icon(LucideIcons.chevronRight, size: 20),
            tooltip: '下一页',
            onPressed: state.currentPage < state.pageCount
                ? notifier.nextPage
                : null,
          ),
          const Spacer(),
          // 批注入口 (FEATURES §5): toggles the mark tools; the tool bar
          // itself floats above the reading area (MarkToolBar) so it has
          // room for the tools + style controls.
          ToolbarIconButton(
            icon: LucideIcons.brush,
            tooltip: '批注',
            active: ref.watch(markToolProvider.select((s) => s.tool != null)),
            onTap: () {
              final armed = ref.read(markToolProvider).tool != null;
              ref
                  .read(markToolProvider.notifier)
                  .setTool(armed ? null : MarkTool.select);
            },
          ),
          // 识图 (region vision, FEATURES 6.6.2 / 7.2): full-window
          // selection; the captured pixels go straight to the vision model
          // and the answer streams into the result card (所选即所得).
          IconButton(
            icon: const Icon(LucideIcons.scanText, size: 20),
            tooltip: '识图',
            onPressed: () {
              final overlay = Overlay.of(context, rootOverlay: true);
              ref
                  .read(screenshotProvider.notifier)
                  .begin(
                    overlay,
                    bookId: state.book?.id,
                    bookTitle: state.book?.title,
                  );
            },
          ),
          // AI side panel (FEATURES 6.5) -- independent of the three sidebars.
          ToolbarIconButton(
            icon: LucideIcons.sparkles,
            tooltip: 'AI',
            active: ref.watch(aiProvider.select((s) => s.aiPanelOpen)),
            onTap: () => ref.read(aiProvider.notifier).togglePanel(),
          ),
        ],
      ),
    );
  }

  Future<void> _showPageJumpDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(viewerProvider);
    final value = await showTextInputDialog(
      context,
      title: '跳转页码',
      initial: '${state.currentPage}',
      label: '页码 (1-${state.pageCount})',
      confirmLabel: '跳转',
      keyboardType: TextInputType.number,
    );
    final page = int.tryParse(value ?? '');
    if (page != null) {
      ref.read(viewerProvider.notifier).setPage(page);
    }
  }
}

/// View-mode selector: one button showing the current mode; a popup offers
/// the three modes (FEATURES 3.1.4).
class _ModeSelector extends ConsumerWidget {
  const _ModeSelector();

  static (IconData, String) _modeInfo(ViewMode mode) {
    switch (mode) {
      case ViewMode.single:
        return (LucideIcons.rows3, '单页');
      case ViewMode.doubleScroll:
        return (LucideIcons.columns2, '双滚');
      case ViewMode.doublePage:
        return (LucideIcons.bookOpenText, '双翻');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(viewerProvider.select((s) => s.mode));
    final theme = Theme.of(context);
    final (icon, label) = _modeInfo(mode);

    return PopupMenuButton<ViewMode>(
      tooltip: '视图模式',
      initialValue: mode,
      onSelected: (m) => ref.read(viewerProvider.notifier).setMode(m),
      itemBuilder: (ctx) => [
        for (final m in ViewMode.values)
          PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(_modeInfo(m).$1, size: 20),
                const SizedBox(width: 8),
                Text(_modeInfo(m).$2),
                if (m == mode) ...[
                  const Spacer(),
                  Icon(
                    LucideIcons.check,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text(label, style: theme.textTheme.bodySmall),
            const SizedBox(width: 2),
            Icon(
              LucideIcons.chevronDown,
              size: 20,
              color: theme.colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
