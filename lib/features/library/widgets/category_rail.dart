import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/library/models/library_filter.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/category_edit_dialog.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Left navigation rail for category-based filtering and drag-classify
/// (FEATURES 2.7 / 2.8).
///
/// Fixed system views (All / Favorites / PDF / Image) sit above the
/// user-defined categories. Each custom category is a [DragTarget] that
/// accepts a dropped [Book] and assigns it. Long-press / secondary-tap on a
/// custom category reveals rename / delete actions.
class CategoryRail extends ConsumerWidget {
  const CategoryRail({super.key});

  static const _fixedWidth = 220.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(libraryFilterProvider);
    final catsAsync = ref.watch(categoriesProvider);

    return SizedBox(
      width: _fixedWidth,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            _SectionLabel('书库'),
            _FixedItem(
              icon: Icons.grid_view_outlined,
              label: '全部',
              selected: filter.view == LibraryView.all,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).showAll(),
            ),
            _FixedItem(
              icon: Icons.star_rounded,
              label: '收藏',
              selected: filter.view == LibraryView.favorite,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).showFavorites(),
            ),
            _FixedItem(
              icon: Icons.picture_as_pdf_outlined,
              label: 'PDF',
              selected: filter.view == LibraryView.pdf,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).showPdf(),
            ),
            _FixedItem(
              icon: Icons.image_outlined,
              label: '图片',
              selected: filter.view == LibraryView.image,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).showImage(),
            ),
            // 查看 AI 对话: standalone entry below the bookshelf views and
            // above the categories (FEATURES 6.5.4).
            const Divider(height: 24),
            _FixedItem(
              icon: Icons.forum_outlined,
              label: 'AI 对话',
              selected: false,
              onTap: () => context.go('/ai-chat'),
            ),
            const Divider(height: 24),
            _SectionLabel('分类'),
            ...catsAsync.when(
              data: (cats) => _buildCustomCategories(context, ref, cats, filter),
              loading: () => [const _LoadingHint()],
              error: (_, _) => [const _LoadingHint()],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.add, size: 18),
                label: const Text('新建分类'),
                onPressed: () => _createCategory(context, ref),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCustomCategories(
    BuildContext context,
    WidgetRef ref,
    List<Category> cats,
    LibraryFilter filter,
  ) {
    if (cats.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            '暂无分类',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
        ),
      ];
    }
    return cats
        .map((c) => _CustomCategoryTile(
              category: c,
              selected: filter.view == LibraryView.category &&
                  filter.categoryId == c.id,
              onTap: () =>
                  ref.read(libraryFilterProvider.notifier).setCategory(c.id),
              onRename: () => _renameCategory(context, ref, c),
              onDelete: () => _confirmDelete(context, ref, c),
            ))
        .toList();
  }

  Future<void> _createCategory(BuildContext context, WidgetRef ref) async {
    final name = await showCategoryEditDialog(context, title: '新建分类');
    if (name == null || name.trim().isEmpty) return;
    final created =
        await ref.read(categoriesProvider.notifier).create(name.trim());
    if (!context.mounted) return;
    if (created == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分类名称已存在')),
      );
    }
  }

  Future<void> _renameCategory(
    BuildContext context,
    WidgetRef ref,
    Category c,
  ) async {
    final name = await showCategoryEditDialog(
      context,
      title: '重命名分类',
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('删除「${c.name}」？该分类下的书籍将变为未分类。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(categoriesProvider.notifier).delete(c.id);
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
      ),
    );
  }
}

class _FixedItem extends StatelessWidget {
  const _FixedItem({
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
    return ListTile(
      leading: Icon(icon,
          color: selected ? scheme.primary : scheme.onSurfaceVariant),
      title: Text(label,
          style: TextStyle(
            color: selected ? scheme.primary : scheme.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          )),
      selected: selected,
      onTap: onTap,
    );
  }
}

/// A custom category tile that is also a [DragTarget] for [Book] (FEATURES 2.8).
/// Accepting a dropped book assigns it to this category via the books notifier.
class _CustomCategoryTile extends ConsumerWidget {
  const _CustomCategoryTile({
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
        return Container(
          color: hovering ? scheme.primaryContainer : null,
          child: ListTile(
            leading: Icon(Icons.label_outline,
                color: selected ? scheme.primary : scheme.onSurfaceVariant),
            title: Text(
              category.name,
              style: TextStyle(
                color: selected ? scheme.primary : scheme.onSurface,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            selected: selected,
            onTap: onTap,
            onLongPress: () => _showActions(context),
          ),
        );
      },
    );
  }

  void _showActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.pop(ctx);
                onRename();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: Text('删除',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                onDelete();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingHint extends StatelessWidget {
  const _LoadingHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.all(16),
      child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
    );
  }
}
