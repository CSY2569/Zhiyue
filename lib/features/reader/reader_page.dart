import 'package:flutter/material.dart';

/// Reader page (FEATURES §3, §4, §5).
///
/// Skeleton for M2+: toolbar placeholders (view modes / zoom / paging) and a
/// main content area placeholder. Three sidebars (thumbnails / outline /
/// annotations) are toggled via the toolbar. Real PDF rendering, selection,
/// and annotations land in milestones M2-M5.
class ReaderPage extends StatelessWidget {
  const ReaderPage({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          _ReaderToolbar(theme: theme),
          Expanded(
            child: Center(
              child: Text(
                '阅读器（书籍 #$bookId）\nPDF 渲染管线将在 M2 实现',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reader toolbar (FEATURES 3.1.4, 3.2.1, 3.3.1, 3.4).
///
/// All buttons are placeholders for the skeleton; wiring lands in M2.
class _ReaderToolbar extends StatelessWidget {
  const _ReaderToolbar({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
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
          // View mode switch (single / double scroll / double page) -- 3.1.4
          _IconBtn(Icons.view_agenda_outlined, '视图模式', () {}),
          const Divider(indent: 8, endIndent: 8),
          // Zoom controls -- 3.2.1
          _IconBtn(Icons.zoom_out, '缩小', () {}),
          const Text('120%'),
          _IconBtn(Icons.zoom_in, '放大', () {}),
          const Divider(indent: 8, endIndent: 8),
          // Paging -- 3.3.1
          _IconBtn(Icons.chevron_left, '上一页', () {}),
          const Text('1 / 1'),
          _IconBtn(Icons.chevron_right, '下一页', () {}),
          const Spacer(),
          // Sidebars -- 3.4
          _IconBtn(Icons.view_list_outlined, '缩略图', () {}),
          _IconBtn(Icons.account_tree_outlined, '目录', () {}),
          _IconBtn(Icons.bookmark_border, '标注', () {}),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn(this.icon, this.tooltip, this.onPressed);
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
