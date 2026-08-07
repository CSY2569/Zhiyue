import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart'
    show MarkTool, markToolProvider;
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
          _SidebarToggle(
            icon: Icons.view_list_outlined,
            label: '缩略图',
            active: state.openSidebar == SidebarType.thumbnails,
            onTap: () => notifier.toggleSidebar(SidebarType.thumbnails),
          ),
          _SidebarToggle(
            icon: Icons.account_tree_outlined,
            label: '目录',
            active: state.openSidebar == SidebarType.outline,
            onTap: () => notifier.toggleSidebar(SidebarType.outline),
          ),
          _SidebarToggle(
            icon: Icons.bookmark_border,
            label: '标注',
            active: state.openSidebar == SidebarType.annotations,
            onTap: () => notifier.toggleSidebar(SidebarType.annotations),
          ),
          _SidebarToggle(
            icon: Icons.layers_outlined,
            label: '标记',
            active: state.openSidebar == SidebarType.imageMarks,
            onTap: () => notifier.toggleSidebar(SidebarType.imageMarks),
          ),
          const _Divider(),
          // View mode selector (3.1): one popup for the three modes.
          const _ModeSelector(),
          const _Divider(),
          // Zoom (3.2.1)
          IconButton(
            icon: const Icon(Icons.zoom_out, size: 20),
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
            icon: const Icon(Icons.zoom_in, size: 20),
            tooltip: '放大',
            onPressed: notifier.zoomIn,
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt, size: 18),
            tooltip: '恢复缩放',
            onPressed: notifier.resetZoom,
          ),
          const _Divider(),
          // Paging (3.3.1)
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
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
            icon: const Icon(Icons.chevron_right, size: 20),
            tooltip: '下一页',
            onPressed: state.currentPage < state.pageCount
                ? notifier.nextPage
                : null,
          ),
          const Spacer(),
          // 批注入口 (FEATURES §5): toggles the mark tools; the tool bar
          // itself floats above the reading area (MarkToolBar) so it has
          // room for the tools + style controls.
          _SidebarToggle(
            icon: Icons.brush_outlined,
            label: '批注',
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
            icon: const Icon(Icons.document_scanner_outlined, size: 20),
            tooltip: '识图',
            onPressed: () {
              final overlay = Overlay.of(context, rootOverlay: true);
              ref.read(screenshotProvider.notifier).begin(
                    overlay,
                    bookId: state.book?.id,
                    bookTitle: state.book?.title,
                  );
            },
          ),
          // AI side panel (FEATURES 6.5) -- independent of the three sidebars.
          _SidebarToggle(
            icon: Icons.auto_awesome_outlined,
            label: 'AI',
            active: ref.watch(aiProvider.select((s) => s.aiPanelOpen)),
            onTap: () => ref.read(aiProvider.notifier).togglePanel(),
          ),
        ],
      ),
    );
  }

  Future<void> _showPageJumpDialog(BuildContext context, WidgetRef ref) async {
    final state = ref.read(viewerProvider);
    final controller = TextEditingController(text: '${state.currentPage}');
    final page = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('跳转页码'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '页码 (1-${state.pageCount})',
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) {
            final n = int.tryParse(v);
            Navigator.pop(ctx, n);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text);
              Navigator.pop(ctx, n);
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
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
        return (Icons.view_stream_outlined, '单页');
      case ViewMode.doubleScroll:
        return (Icons.view_agenda_outlined, '双滚');
      case ViewMode.doublePage:
        return (Icons.menu_book_outlined, '双翻');
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
                Icon(_modeInfo(m).$1, size: 18),
                const SizedBox(width: 8),
                Text(_modeInfo(m).$2),
                if (m == mode) ...[
                  const Spacer(),
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
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
            Icon(Icons.arrow_drop_down,
                size: 18, color: theme.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

class _SidebarToggle extends StatelessWidget {
  const _SidebarToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: IconButton(
        icon: Icon(icon, size: 20),
        color: active ? theme.colorScheme.primary : null,
        visualDensity: VisualDensity.compact,
        onPressed: onTap,
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}
