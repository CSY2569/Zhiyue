import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/core/widgets/text_input_dialog.dart';
import 'package:rbwa/platform/platform_host.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/outline_settings.dart';
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/pdf/types.dart';

/// Document outline / table of contents sidebar (FEATURES 3.4.2).
///
/// Fetches the bookmark tree from Rust and renders it as an expandable list.
/// Tapping an entry jumps to its page. If the document has no outline, a
/// hint is shown.
class OutlineTree extends ConsumerStatefulWidget {
  const OutlineTree({super.key, required this.onJump});

  final void Function(int page) onJump;

  @override
  ConsumerState<OutlineTree> createState() => _OutlineTreeState();
}

class _OutlineTreeState extends ConsumerState<OutlineTree> {
  List<OutlineEntry>? _entries;
  String? _error;
  bool _loading = true;
  int _bookId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = ref.read(viewerProvider);
    final repo = ref.read(readerRepositoryProvider);
    _bookId = state.book?.id ?? 0;
    try {
      final result = await repo.getOutline(_bookId);
      if (mounted) {
        setState(() {
          _entries = result.entries;
          _error = result.error;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  /// Rename / hide / bookmark actions for one node.
  ///
  /// Edits go through the override table, so the PDF file itself never changes
  /// -- the merged tree is rebuilt from the document outline plus these rows.
  Future<void> _editNode(OutlineEntry entry, _OutlineAction action) async {
    final repo = ref.read(readerRepositoryProvider);
    switch (action) {
      case _OutlineAction.rename:
        final title = await showTextInputDialog(
          context,
          title: '重命名目录项',
          initial: entry.title,
          label: '标题',
        );
        if (title == null || title.isEmpty) return;
        await repo.saveOutlineOverride(
          bookId: _bookId,
          entryKey: entry.key,
          title: title,
        );
      case _OutlineAction.hide:
        await repo.saveOutlineOverride(
          bookId: _bookId,
          entryKey: entry.key,
          hidden: true,
        );
      case _OutlineAction.bookmark:
        // A bookmark is a NEW node (bm: key) parented to this entry, aimed at
        // the page the user is currently reading.
        final page = ref.read(viewerProvider).currentPage;
        final title = await showTextInputDialog(
          context,
          title: '添加书签',
          initial: '第 $page 页',
          label: '书签名称',
        );
        if (title == null || title.isEmpty) return;
        await repo.saveOutlineOverride(
          bookId: _bookId,
          entryKey: 'bm:${DateTime.now().microsecondsSinceEpoch}',
          parentKey: entry.key,
          title: title,
          page: page - 1, // Flutter is 1-based, the outline is 0-based
        );
      case _OutlineAction.reset:
        await repo.resetOutline(_bookId);
    }
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = ref.watch(panelLayoutProvider.select((p) => p.outlineWidth));
    return SizedBox(
      width: width,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const LoadingState();
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('加载目录失败: $_error', style: theme.textTheme.bodySmall),
      );
    }
    final entries = _entries ?? [];
    if (entries.isEmpty) {
      return const EmptyState(
        icon: LucideIcons.network,
        title: '无目录大纲',
        iconSize: 40,
      );
    }
    // 设置 → 阅读器: whether every level starts expanded. Toggling it re-keys
    // the list below so the nodes pick up the new default immediately.
    final expandAll = ref.watch(outlineExpandAllProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 4, top: 4),
          child: Row(
            children: [
              Expanded(
                child: Text('目录', style: theme.textTheme.labelMedium),
              ),
              PopupMenuButton<_OutlineAction>(
                tooltip: '目录选项',
                icon: const Icon(LucideIcons.ellipsisVertical, size: 20),
                onSelected: (action) {
                  // Reset applies to the whole book, not to one node.
                  final first = _entries?.isNotEmpty == true
                      ? _entries!.first
                      : null;
                  if (first != null) _editNode(first, action);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: _OutlineAction.reset,
                    child: Text('恢复原始目录'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            key: ValueKey(expandAll),
            padding: const EdgeInsets.symmetric(vertical: 8),
      children: entries
          .map(
            (e) => _OutlineNode(
              entry: e,
              depth: 0,
              defaultExpanded: expandAll,
              onJump: (page) => widget.onJump(page),
              onAction: _editNode,
            ),
          )
              .toList(),
          ),
        ),
      ],
    );
  }
}

/// A single outline node with expandable children.
class _OutlineNode extends StatefulWidget {
  const _OutlineNode({
    required this.entry,
    required this.depth,
    required this.defaultExpanded,
    required this.onJump,
    required this.onAction,
  });

  final OutlineEntry entry;
  final int depth;

  /// Context-menu actions (rename / hide / add bookmark) for this node.
  final void Function(OutlineEntry entry, _OutlineAction action) onAction;

  /// Whether this node's children start expanded (设置 → 阅读器, inherited by
  /// every descendant so "expand all" reaches the whole tree).
  final bool defaultExpanded;
  final void Function(int page) onJump;

  @override
  State<_OutlineNode> createState() => _OutlineNodeState();
}

class _OutlineNodeState extends State<_OutlineNode> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.defaultExpanded;
  }

  /// Right-click (desktop) or long-press (touch) menu for this node.
  Future<void> _showMenu(Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final selected = await showMenu<_OutlineAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: _OutlineAction.rename, child: Text('重命名')),
        PopupMenuItem(value: _OutlineAction.bookmark, child: Text('在此添加书签')),
        PopupMenuItem(value: _OutlineAction.hide, child: Text('隐藏此项')),
      ],
    );
    if (selected != null) widget.onAction(widget.entry, selected);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = widget.entry.children.isNotEmpty;
    final page = widget.entry.page;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: page >= 0 ? () => widget.onJump(page) : null,
          onSecondaryTapDown: (d) => _showMenu(d.globalPosition),
          // Touch has no right-click; long-press opens the same menu. Desktop
          // keeps long-press free so it can still drag-select text elsewhere.
          onLongPress: PlatformHost.current.touch
              ? () {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box != null) {
                    _showMenu(box.localToGlobal(box.size.center(Offset.zero)));
                  }
                }
              : null,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16.0 + widget.depth * 16,
              right: 12,
              top: 6,
              bottom: 6,
            ),
            child: Row(
              children: [
                if (hasChildren)
                  GestureDetector(
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Icon(
                      _expanded
                          ? LucideIcons.chevronDown
                          : LucideIcons.chevronRight,
                      size: 20,
                      color: theme.colorScheme.outline,
                    ),
                  )
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.entry.title.isEmpty ? '(未命名)' : widget.entry.title,
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (page >= 0)
                  Text(
                    '${page + 1}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (hasChildren && _expanded)
          ...widget.entry.children.map(
            (child) => _OutlineNode(
              entry: child,
              depth: widget.depth + 1,
              defaultExpanded: widget.defaultExpanded,
              onJump: widget.onJump,
              onAction: widget.onAction,
            ),
          ),
      ],
    );
  }
}
/// What the outline context menu can do to a node.
enum _OutlineAction { rename, hide, bookmark, reset }
