import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/navigation.dart';
import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart'
    show MarkTool, markToolProvider;
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/screenshot/screenshot_provider.dart';
import 'package:rbwa/core/widgets/text_input_dialog.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Mobile reading chrome: a translucent top bar, a five-item bottom bar, and
/// a "more" sheet for the rest.
///
/// The desktop [ReaderToolbar] packs ~700dp of controls into one 48dp row,
/// which overflows a 360dp phone (the right-hand buttons become unreachable).
/// Phones instead get two thumb-reach bars plus a sheet:
///
/// ```
/// ┌──────────────────────────────┐   top: back · title · page · more
/// │                              │
/// │           page               │   tap the middle to toggle chrome
/// │                              │
/// ├──────────────────────────────┤   bottom: 目录 缩略图 批注 AI 更多
/// └──────────────────────────────┘
/// ```
///
/// Everything in the sheet delegates to the same providers as the desktop
/// toolbar, so behavior stays identical across platforms.
class PhoneReaderTopBar extends ConsumerWidget {
  const PhoneReaderTopBar({super.key, required this.onShowMore});

  final VoidCallback onShowMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(viewerProvider);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      elevation: 1,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                tooltip: '返回书库',
                icon: const Icon(LucideIcons.arrowLeft, size: 24),
                onPressed: () => navigateBack(GoRouter.of(context)),
              ),
              Expanded(
                child: Text(
                  state.book?.title ?? '阅读器',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              // Page indicator doubles as the jump entry (48dp target).
              InkWell(
                onTap: () => showPhonePageJump(context, ref),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  child: Text(
                    '${state.currentPage} / ${state.pageCount}',
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: '更多',
                icon: const Icon(LucideIcons.moreHorizontal, size: 24),
                onPressed: onShowMore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom action bar: the five most frequent reading actions.
class PhoneReaderBottomBar extends ConsumerWidget {
  const PhoneReaderBottomBar({super.key, required this.onShowMore});

  final VoidCallback onShowMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(viewerProvider);
    final theme = Theme.of(context);
    final aiOpen = ref.watch(aiProvider.select((s) => s.aiPanelOpen));
    final markArmed = ref.watch(markToolProvider.select((s) => s.tool != null));

    return Material(
      color: theme.colorScheme.surface.withValues(alpha: 0.94),
      elevation: 2,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _BarItem(
                icon: LucideIcons.list,
                label: '缩略图',
                active: state.openSidebar == SidebarType.thumbnails,
                onTap: () => ref
                    .read(viewerProvider.notifier)
                    .toggleSidebar(SidebarType.thumbnails),
              ),
              _BarItem(
                icon: LucideIcons.network,
                label: '目录',
                active: state.openSidebar == SidebarType.outline,
                onTap: () => ref
                    .read(viewerProvider.notifier)
                    .toggleSidebar(SidebarType.outline),
              ),
              _BarItem(
                icon: LucideIcons.brush,
                label: '批注',
                active: markArmed,
                onTap: () {
                  ref
                      .read(markToolProvider.notifier)
                      .setTool(markArmed ? null : MarkTool.select);
                },
              ),
              _BarItem(
                icon: LucideIcons.sparkles,
                label: 'AI',
                active: aiOpen,
                onTap: () => ref.read(aiProvider.notifier).togglePanel(),
              ),
              _BarItem(
                icon: LucideIcons.moreHorizontal,
                label: '更多',
                onTap: onShowMore,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = active
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// The "more" sheet: view mode, zoom, 对照, 识图, annotations, page jump.
Future<void> showPhoneReaderMoreSheet(BuildContext context, WidgetRef ref) {
  final mode = ref.read(viewerProvider).mode;
  final translateOpen = ref.read(translationPaneProvider).open;
  final marked =
      ref.read(viewerProvider).openSidebar == SidebarType.annotations;

  return showAppSheet<void>(
    context,
    title: '视图与工具',
    children: [
      AppSheetItem(
        icon: LucideIcons.languages,
        label: '对照阅读',
        trailing: translateOpen ? '已开启' : null,
        selected: translateOpen,
        onTap: () {
          Navigator.pop(context);
          ref.read(translationPaneProvider.notifier).toggle();
        },
      ),
      AppSheetItem(
        icon: LucideIcons.scanText,
        label: '识图',
        onTap: () {
          Navigator.pop(context);
          final overlay = Overlay.of(context, rootOverlay: true);
          final state = ref.read(viewerProvider);
          ref.read(screenshotProvider.notifier).begin(
                overlay,
                bookId: state.book?.id,
                bookTitle: state.book?.title,
              );
        },
      ),
      AppSheetItem(
        icon: LucideIcons.bookmark,
        label: '标注',
        selected: marked,
        trailing: marked ? '已开启' : null,
        onTap: () {
          Navigator.pop(context);
          ref
              .read(viewerProvider.notifier)
              .toggleSidebar(SidebarType.annotations);
        },
      ),
      AppSheetItem(
        icon: LucideIcons.zoomIn,
        label: '缩放',
        trailing: '${(ref.read(viewerProvider).zoom * 100).round()}%',
        onTap: () {
          Navigator.pop(context);
          _showPhoneZoomSheet(context, ref);
        },
      ),
      AppSheetItem(
        icon: LucideIcons.rows3,
        label: '视图模式',
        trailing: mode == ViewMode.single ? '单页' : '双页',
        onTap: () {
          Navigator.pop(context);
          // A phone shows one page; a wide tablet offers the other modes.
          if (PlatformCapabilities.isCompactWidth(
            MediaQuery.sizeOf(context).width,
          )) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('竖屏手机仅有单页模式，横屏或平板可切换双页')),
            );
            return;
          }
          _showPhoneModeSheet(context, ref);
        },
      ),
      AppSheetItem(
        icon: LucideIcons.hash,
        label: '跳转页码',
        onTap: () {
          Navigator.pop(context);
          showPhonePageJump(context, ref);
        },
      ),
    ],
  );
}

/// Zoom controls in a sheet (the phone chrome has no room for a slider row).
Future<void> _showPhoneZoomSheet(BuildContext context, WidgetRef ref) {
  return showAppSheet<void>(
    context,
    title: '缩放',
    children: [
      StatefulBuilder(
        builder: (context, setState) {
          final zoom = ref.watch(viewerProvider.select((s) => s.zoom));
          final notifier = ref.read(viewerProvider.notifier);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 21),
            child: Row(
              children: [
                IconButton(
                  tooltip: '缩小',
                  icon: const Icon(LucideIcons.zoomOut, size: 20),
                  onPressed: () {
                    notifier.zoomOut();
                    setState(() {});
                  },
                ),
                Expanded(
                  child: Slider(
                    value: zoom.clamp(0.3, 4.0),
                    min: 0.3,
                    max: 4.0,
                    divisions: 37,
                    label: '${(zoom * 100).round()}%',
                    onChanged: notifier.setZoom,
                  ),
                ),
                IconButton(
                  tooltip: '放大',
                  icon: const Icon(LucideIcons.zoomIn, size: 20),
                  onPressed: () {
                    notifier.zoomIn();
                    setState(() {});
                  },
                ),
                IconButton(
                  tooltip: '恢复',
                  icon: const Icon(LucideIcons.rotateCcw, size: 20),
                  onPressed: () {
                    notifier.resetZoom();
                    setState(() {});
                  },
                ),
              ],
            ),
          );
        },
      ),
    ],
  );
}

/// View-mode picker for wide screens.
Future<void> _showPhoneModeSheet(BuildContext context, WidgetRef ref) {
  final mode = ref.read(viewerProvider).mode;
  AppSheetItem item(ViewMode m, IconData icon, String label) => AppSheetItem(
        icon: icon,
        label: label,
        selected: mode == m,
        onTap: () {
          ref.read(viewerProvider.notifier).setMode(m);
          Navigator.pop(context);
        },
      );
  return showAppSheet<void>(
    context,
    title: '视图模式',
    children: [
      item(ViewMode.single, LucideIcons.rows3, '单页'),
      item(ViewMode.doubleScroll, LucideIcons.columns2, '双页滚动'),
      item(ViewMode.doublePage, LucideIcons.bookOpen, '双页翻页'),
    ],
  );
}

/// Page-jump dialog shared by the top bar and the more sheet.
Future<void> showPhonePageJump(BuildContext context, WidgetRef ref) async {
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
