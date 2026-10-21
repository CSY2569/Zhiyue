import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/core/widgets/confirm_dialog.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/category_edit_dialog.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Left navigation rail (FEATURES 2.7 / 2.8).
///
/// Mirrors the reference design's organisation: a three-way segmented switch
/// at the top (导航 / 文件夹 / 标签) that swaps which *kind* of entry the list
/// below shows, then a flat list of entries.
///
///  * **导航** -- system views (所有文档 / 最近使用 / 我的收藏 / PDF / 图片)
///    plus the AI conversation entry and the utility links.
///  * **文件夹** -- user categories; each is a drop target for a dragged book
///    and offers rename / delete on long-press.
///  * **标签** -- reserved: the schema has categories, not tags, so this tab
///    explains that instead of pretending to work.
class CategoryRail extends ConsumerStatefulWidget {
  const CategoryRail({super.key, this.width = Golden.railDefaultWidth});

  final double width;

  @override
  ConsumerState<CategoryRail> createState() => _CategoryRailState();
}

enum _RailTab { nav, folders, tags }

class _CategoryRailState extends ConsumerState<CategoryRail> {
  _RailTab _tab = _RailTab.nav;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Golden.s13,
              Golden.s13,
              Golden.s13,
              Golden.s8,
            ),
            child: _Segmented(
              value: _tab,
              onChanged: (t) => setState(() => _tab = t),
            ),
          ),
          Expanded(
            child: switch (_tab) {
              _RailTab.nav => const _NavList(),
              _RailTab.folders => const _FolderList(),
              _RailTab.tags => const _TagsPlaceholder(),
            },
          ),
        ],
      ),
    );
  }
}

/// The three-way pill switch at the top of the rail.
class _Segmented extends StatelessWidget {
  const _Segmented({required this.value, required this.onChanged});

  final _RailTab value;
  final ValueChanged<_RailTab> onChanged;

  static const _labels = {
    _RailTab.nav: '导航',
    _RailTab.folders: '文件夹',
    _RailTab.tags: '标签',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (final entry in _labels.entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(entry.key),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: entry.key == value
                        ? scheme.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    entry.value,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: entry.key == value
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: entry.key == value
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// System views + AI + utility links.
class _NavList extends ConsumerWidget {
  const _NavList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Golden.s8,
        Golden.s4,
        Golden.s8,
        Golden.s21,
      ),
      children: [
        _RailItem(
          icon: LucideIcons.library,
          label: '所有文档',
          selected: filter.view == LibraryView.all,
          onTap: () => ref.read(libraryFilterProvider.notifier).showAll(),
        ),
        _RailItem(
          icon: LucideIcons.history,
          label: '最近使用',
          selected: filter.view == LibraryView.recent,
          onTap: () => ref.read(libraryFilterProvider.notifier).showRecent(),
        ),
        _RailItem(
          icon: LucideIcons.heart,
          label: '我的收藏',
          selected: filter.view == LibraryView.favorite,
          onTap: () => ref.read(libraryFilterProvider.notifier).showFavorites(),
        ),
        _RailItem(
          icon: LucideIcons.fileText,
          label: 'PDF',
          selected: filter.view == LibraryView.pdf,
          onTap: () => ref.read(libraryFilterProvider.notifier).showPdf(),
        ),
        _RailItem(
          icon: LucideIcons.image,
          label: '图片',
          selected: filter.view == LibraryView.image,
          onTap: () => ref.read(libraryFilterProvider.notifier).showImage(),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Golden.s13,
            vertical: Golden.s8,
          ),
          child: Divider(
            height: 1,
            color: scheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
        _RailItem(
          icon: LucideIcons.messagesSquare,
          label: 'AI 对话',
          selected: false,
          onTap: () => context.push('/ai-chat'),
        ),
        _RailItem(
          icon: LucideIcons.search,
          label: '全文搜索',
          selected: false,
          onTap: () => context.push('/search'),
        ),
        _RailItem(
          icon: LucideIcons.settings,
          label: '设置',
          selected: false,
          onTap: () => context.push('/settings'),
        ),
      ],
    );
  }
}

/// User categories (folders): drag target + long-press actions.
class _FolderList extends ConsumerWidget {
  const _FolderList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final catsAsync = ref.watch(categoriesProvider);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Golden.s8,
        Golden.s4,
        Golden.s8,
        Golden.s21,
      ),
      children: [
        catsAsync.when(
          data: (cats) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cats.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Golden.s13,
                    Golden.s8,
                    Golden.s13,
                    Golden.s8,
                  ),
                  child: Text(
                    '还没有文件夹。\n新建一个，然后把书拖进去。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.5,
                        ),
                  ),
                ),
              for (final c in cats)
                _FolderTile(
                  category: c,
                  selected: filter.view == LibraryView.category &&
                      filter.categoryId == c.id,
                  onTap: () =>
                      ref.read(libraryFilterProvider.notifier).setCategory(c.id),
                  onRename: () => _rename(context, ref, c),
                  onDelete: () => _confirmDelete(context, ref, c),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Golden.s8,
                  Golden.s13,
                  Golden.s8,
                  Golden.s8,
                ),
                child: OutlinedButton.icon(
                  icon: const Icon(LucideIcons.folderPlus, size: 20),
                  label: const Text('新建文件夹'),
                  onPressed: () => _create(context, ref),
                ),
              ),
            ],
          ),
          loading: () => const Padding(
            padding: EdgeInsets.all(Golden.s21),
            child: Center(child: InlineSpinner(size: 16)),
          ),
          error: (_, _) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final name = await showCategoryEditDialog(context, title: '新建文件夹');
    if (name == null || name.trim().isEmpty) return;
    final created =
        await ref.read(categoriesProvider.notifier).create(name.trim());
    if (!context.mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称已存在')),
      );
    }
  }

  Future<void> _rename(
    BuildContext context,
    WidgetRef ref,
    Category c,
  ) async {
    final name = await showCategoryEditDialog(
      context,
      title: '重命名文件夹',
      initial: c.name,
    );
    if (name == null || name.trim().isEmpty || name.trim() == c.name) return;
    await ref.read(categoriesProvider.notifier).rename(c.id, name.trim());
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Category c,
  ) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除文件夹',
      content: '删除「${c.name}」？其中的书会回到未分类，不会被删除。',
      confirmStyle: ConfirmButtonStyle.plain,
    );
    if (ok) {
      await ref.read(categoriesProvider.notifier).delete(c.id);
    }
  }
}

class _TagsPlaceholder extends StatelessWidget {
  const _TagsPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(Golden.s13),
      children: [
        Text(
          '标签',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Golden.s8),
        Text(
          '暂未支持多标签。目前请用「文件夹」整理书籍：一本书可以属于一个文件夹。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

/// One navigation row: rounded pill highlight when selected.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: selected
            ? scheme.primaryContainer.withValues(alpha: 0.55)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Golden.s13,
              vertical: Golden.s13,
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: Golden.s13),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontSize: 14,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A folder row: drag target, long-press to rename / delete.
class _FolderTile extends ConsumerWidget {
  const _FolderTile({
    required this.category,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final Category category;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<Book>(
      onAcceptWithDetails: (details) {
        ref
            .read(libraryBooksProvider.notifier)
            .assignCategory(details.data.id, category.id);
      },
      builder: (context, candidate, rejected) {
        final hovering = candidate.isNotEmpty;
        final bg = hovering
            ? scheme.primaryContainer
            : selected
                ? scheme.primaryContainer.withValues(alpha: 0.55)
                : Colors.transparent;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Material(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: onTap,
              onLongPress: () => _actions(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Golden.s13,
                  vertical: Golden.s13,
                ),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.folder,
                      size: 20,
                      color:
                          selected ? scheme.primary : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: Golden.s13),
                    Expanded(
                      child: Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected ? scheme.primary : scheme.onSurface,
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _actions(BuildContext context) {
    showAppSheet<void>(
      context,
      title: category.name,
      children: [
        AppSheetItem(
          icon: LucideIcons.pen,
          label: '重命名',
          onTap: () {
            Navigator.pop(context);
            onRename();
          },
        ),
        AppSheetItem(
          icon: LucideIcons.trash2,
          label: '删除文件夹',
          danger: true,
          onTap: () {
            Navigator.pop(context);
            onDelete();
          },
        ),
      ],
    );
  }
}
