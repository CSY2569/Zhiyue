import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = ref.read(viewerProvider);
    final repo = ref.read(readerRepositoryProvider);
    try {
      final result = await repo.getOutline(state.book?.id ?? 0);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 240,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('加载目录失败: $_error',
              style: theme.textTheme.bodySmall),
        ),
      );
    }
    final entries = _entries ?? [];
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 8),
              Text('无目录大纲', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: entries.map((e) => _OutlineNode(
        entry: e,
        depth: 0,
        onJump: (page) => widget.onJump(page),
      )).toList(),
    );
  }
}

/// A single outline node with expandable children.
class _OutlineNode extends StatefulWidget {
  const _OutlineNode({
    required this.entry,
    required this.depth,
    required this.onJump,
  });

  final OutlineEntry entry;
  final int depth;
  final void Function(int page) onJump;

  @override
  State<_OutlineNode> createState() => _OutlineNodeState();
}

class _OutlineNodeState extends State<_OutlineNode> {
  bool _expanded = false;

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
                          ? Icons.expand_more
                          : Icons.chevron_right,
                      size: 18,
                      color: theme.colorScheme.outline,
                    ),
                  )
                else
                  const SizedBox(width: 18),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    widget.entry.title.isEmpty
                        ? '(未命名)'
                        : widget.entry.title,
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
          ...widget.entry.children.map((child) => _OutlineNode(
                entry: child,
                depth: widget.depth + 1,
                onJump: widget.onJump,
              )),
      ],
    );
  }
}
