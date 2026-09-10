import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/core/widgets/confirm_dialog.dart';
import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/widgets/book_grid.dart';
import 'package:rbwa/features/library/widgets/category_assign_dialog.dart';
import 'package:rbwa/features/library/widgets/category_rail.dart';
import 'package:rbwa/features/library/widgets/library_toolbar.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Library / bookshelf page (FEATURES §2).
///
/// Layout: [CategoryRail] on the left, a [Scaffold] with [LibraryToolbar]
/// and [BookGrid] (or the empty-state guide) on the right. The import FAB
/// opens a multi-select file picker; books are copied into the app data dir
/// and de-duplicated by original path in Rust.
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      children: [
        const CategoryRail(),
        Expanded(
          child: Scaffold(
            appBar: LibraryToolbar(
              onToggleTheme: () => _toggleTheme(ref),
              onOpenSettings: () => context.go('/settings'),
            ),
            body: _Body(onBookTap: (b) => _openBook(context, ref, b)),
            floatingActionButton: FloatingActionButton.extended(
              icon: const Icon(Icons.add),
              label: const Text('导入文档'),
              onPressed: () => _import(context, ref),
            ),
          ),
        ),
      ],
    );
  }

  void _toggleTheme(WidgetRef ref) {
    final notifier = ref.read(themeControllerProvider.notifier);
    final current = ref.read(themeControllerProvider);
    notifier.set(
      current == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
    );
  }

  void _openBook(BuildContext context, WidgetRef ref, Book book) {
    // Record the open for the recent-open sort (FEATURES 2.3).
    ref.read(libraryBooksProvider.notifier).touchLastOpened(book.id);
    if (context.mounted) {
      context.go('/reader/${book.id}');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf', 'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tiff', 'tif',
      ],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final paths =
        result.files.where((f) => f.path != null).map((f) => f.path!).toList();
    if (paths.isEmpty) return;

    final summary =
        await ref.read(libraryBooksProvider.notifier).importFiles(paths);
    if (!context.mounted) return;

    final parts = <String>[];
    if (summary.imported > 0) parts.add('导入 ${summary.imported} 本');
    if (summary.alreadyExisted > 0) parts.add('已存在 ${summary.alreadyExisted} 本');
    if (summary.failed > 0) parts.add('失败 ${summary.failed} 本');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(parts.isEmpty ? '未导入任何文档' : parts.join('，'))),
    );
  }
}

/// Body: shows the empty-state guide when the library has no books, the grid
/// when it does, or a loading indicator while fetching.
class _Body extends ConsumerWidget {
  const _Body({required this.onBookTap});

  final void Function(Book book) onBookTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(libraryBooksProvider);

    // Full-text index pre-build (M6, 3.5.1): refresh statuses and trigger
    // background builds for books without an index (app start heals legacy
    // imports). Post-frame -- must not touch providers during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(searchIndexStatusProvider.notifier).refresh();
    });

    return booksAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载书库失败：$e')),
      data: (books) {
        if (books.isEmpty) {
          return const _EmptyLibraryGuide();
        }
        return BookGrid(
          onBookTap: onBookTap,
          onToggleFavorite: (b) =>
              ref.read(libraryBooksProvider.notifier).toggleFavorite(b.id),
          onAssignCategory: (b) => _assignCategory(context, ref, b),
          onDelete: (b) => _confirmDelete(context, ref, b),
        );
      },
    );
  }

  /// Assign (or clear) the category of a book via the context menu
  /// (FEATURES 2.8).
  Future<void> _assignCategory(
    BuildContext context,
    WidgetRef ref,
    Book book,
  ) async {
    final result = await showCategoryAssignDialog(context, book);
    if (result == null) return; // cancelled
    await ref
        .read(libraryBooksProvider.notifier)
        .assignCategory(book.id, result.$1);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Book book,
  ) async {
    final ok = await showConfirmDialog(
      context,
      title: '删除书籍',
      content: '确定删除「${book.title}」？\n阅读进度、标注、OCR 缓存将一并清除。\n'
          'AI 对话将保留，可在书库菜单或 AI 面板中查看。',
    );
    if (ok) {
      await ref.read(libraryBooksProvider.notifier).deleteBook(book.id);
    }
  }
}

/// Empty-state guide (FEATURES 2.2): explains supported formats + import entry.
class _EmptyLibraryGuide extends StatelessWidget {
  const _EmptyLibraryGuide();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return EmptyState(
      icon: Icons.menu_book_outlined,
      iconSize: 80,
      title: '书库为空',
      titleStyle: theme.textTheme.headlineSmall,
      message: '点击右下角「导入文档」添加 PDF 或图片',
      messageStyle: theme.textTheme.bodyMedium?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
      extra: '支持格式：PDF / PNG / JPG / WEBP / BMP / GIF / TIFF',
    );
  }
}
