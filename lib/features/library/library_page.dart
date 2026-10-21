import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/platform/platform.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/core/widgets/confirm_dialog.dart';
import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/core/widgets/search_field.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/library/providers/library_selection_provider.dart';
import 'package:rbwa/features/library/widgets/library_selection_bar.dart';
import 'package:rbwa/features/library/widgets/book_grid.dart';
import 'package:rbwa/features/library/widgets/category_assign_dialog.dart';
import 'package:rbwa/features/library/widgets/category_rail.dart';
import 'package:rbwa/features/library/widgets/floating_panels.dart';
import 'package:rbwa/features/library/widgets/library_filter_bar.dart';
import 'package:rbwa/src/rust/models/book.dart';

/// Library / bookshelf page (FEATURES §2).
///
/// Layout follows the reference design's floating-panel shell: a rounded
/// navigation panel (rail) beside a rounded content panel, both floating on
/// the window background. The content panel stacks a header (title +
/// search), a segmented filter row, and the book shelf. The import FAB opens
/// a multi-select file picker; books are copied into the app data dir and
/// de-duplicated by original path in Rust.
class LibraryPage extends ConsumerStatefulWidget {
  const LibraryPage({super.key});

  @override
  ConsumerState<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends ConsumerState<LibraryPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final mobile = PlatformCapabilities.current().isMobile &&
        PlatformCapabilities.isCompactWidth(width);
    final allBooks = ref.watch(libraryBooksProvider).valueOrNull;
    final shownBooks = ref.watch(filteredBooksProvider);
    final railWidth = Golden.railWidthFor(width);
    final scheme = Theme.of(context).colorScheme;
    final selecting = ref.watch(
      librarySelectionProvider.select((s) => s.active),
    );

    final content = PanelSurface(
      child: Column(
        children: [
          // Header: page identity + search, inside the content panel.
          _PanelHeader(
            compact: mobile,
            bookCount: allBooks?.length,
            filteredCount: shownBooks.length,
            onOpenDrawer:
                mobile ? () => _scaffoldKey.currentState?.openDrawer() : null,
            onToggleTheme: () => _toggleTheme(ref),
            onOpenSettings: () => context.push('/settings'),
          ),
          // Segmented filter row (the reference design's pill bar).
          LibraryFilterHeader(count: shownBooks.length),
          Expanded(child: _Body(onBookTap: (b) => _openBook(context, ref, b))),
        ],
      ),
    );

    final scaffold = Scaffold(
      key: _scaffoldKey,
      backgroundColor: scheme.surface,
      drawer: mobile
          ? Drawer(
              width: 280,
              child: PanelSurface(
                radius: 0,
                border: false,
                child: SafeArea(child: CategoryRail(width: 280)),
              ),
            )
          : null,
      body: FloatingPanels(
        phone: mobile,
        background: scheme.surface,
        side:
            mobile ? null : PanelSurface(child: CategoryRail(width: railWidth)),
        sideWidth: railWidth,
        content: content,
      ),
      // Bulk-selection actions replace the import FAB while selecting.
      floatingActionButton: selecting
          ? null
          : FloatingActionButton(
              tooltip: '导入文档',
              onPressed: () => _import(context, ref),
              child: const Icon(LucideIcons.plus, size: 24),
            ),
      bottomNavigationBar: const LibrarySelectionBar(),
    );
    return scaffold;
  }

  void _toggleTheme(WidgetRef ref) {
    final notifier = ref.read(themeControllerProvider.notifier);
    final current = ref.read(themeControllerProvider);
    notifier.set(current == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  /// Guards against a double tap pushing two reader routes (a `push` no
  /// longer collapses duplicates the way the old `go` did).
  static DateTime? _lastOpenAt;

  void _openBook(BuildContext context, WidgetRef ref, Book book) {
    final now = DateTime.now();
    if (_lastOpenAt != null &&
        now.difference(_lastOpenAt!).inMilliseconds < 400) {
      return;
    }
    _lastOpenAt = now;
    // Record the open for the recent-open sort (FEATURES 2.3).
    ref.read(libraryBooksProvider.notifier).touchLastOpened(book.id);
    if (context.mounted) {
      // Push (not go): the Android back gesture must return to the library.
      context.push('/reader/${book.id}');
    }
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        'pdf',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'bmp',
        'gif',
        'tiff',
        'tif',
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
    if (summary.alreadyExisted > 0) {
      parts.add('已存在 ${summary.alreadyExisted} 本');
    }
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

    // Full-text index status refresh + pre-build (M6, 3.5.1) now lives inside
    // the notifier (it listens to the book list), so this widget no longer
    // schedules an FFI sweep on every rebuild.

    return booksAsync.when(
      loading: () => const LoadingState(),
      error: (e, _) => EmptyState(
        icon: LucideIcons.circleAlert,
        title: '加载书库失败',
        message: '$e',
      ),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Golden.s34),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A soft disc behind the glyph gives the empty state a focal
            // point without adding an illustration asset.
            Container(
              width: 128,
              height: 128,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: Icon(
                LucideIcons.bookOpenText,
                size: 56,
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: Golden.s34),
            Text('书库为空', style: theme.textTheme.headlineSmall),
            const SizedBox(height: Golden.s13),
            Text(
              '导入 PDF 或图片开始阅读。\n长按书籍可以分类、收藏或删除。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: Golden.s21),
            Text(
              '支持 PDF / PNG / JPG / WEBP / BMP / GIF / TIFF',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Header of the content panel: drawer / title + holdings on the left, search
/// and actions on the right.
///
/// Unlike an AppBar it has no elevation or divider -- the panel is already a
/// raised surface, so a second rule inside it would double the separation.
class _PanelHeader extends ConsumerWidget {
  const _PanelHeader({
    required this.compact,
    required this.bookCount,
    required this.filteredCount,
    required this.onOpenDrawer,
    required this.onToggleTheme,
    required this.onOpenSettings,
  });

  final bool compact;
  final int? bookCount;
  final int? filteredCount;
  final VoidCallback? onOpenDrawer;
  final VoidCallback onToggleTheme;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = bookCount;
    final shown = filteredCount;
    final subtitle = total == null
        ? null
        : (shown != null && shown != total
            ? '$shown / $total 本'
            : '共 $total 本');

    final title = Row(
      children: [
        if (onOpenDrawer != null)
          IconButton(
            icon: const Icon(LucideIcons.menu, size: 20),
            tooltip: '书库与文件夹',
            onPressed: onOpenDrawer,
          ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '我的书库',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'serif',
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? Golden.s8 : Golden.s21,
        Golden.s13,
        Golden.s8,
        Golden.s4,
      ),
      child: Row(
        children: [
          if (compact)
            Expanded(child: title)
          else ...[
            SizedBox(width: 240, child: title),
            const SizedBox(width: Golden.s21),
            Expanded(
              child: DebouncedSearchField(
                hint: '搜索书名…',
                pill: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.65,
                ),
                onChanged: (value) => ref
                    .read(libraryFilterProvider.notifier)
                    .setSearchQuery(value),
              ),
            ),
          ],
          if (compact)
            SizedBox(
              width: 180,
              child: DebouncedSearchField(
                hint: '搜索书名…',
                pill: true,
                fillColor: scheme.surfaceContainerHighest.withValues(
                  alpha: 0.65,
                ),
                onChanged: (value) => ref
                    .read(libraryFilterProvider.notifier)
                    .setSearchQuery(value),
              ),
            ),
          IconButton(
            icon: const Icon(LucideIcons.sunMoon, size: 20),
            tooltip: '切换主题',
            onPressed: onToggleTheme,
          ),
          IconButton(
            icon: const Icon(LucideIcons.settings, size: 20),
            tooltip: '设置',
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}
