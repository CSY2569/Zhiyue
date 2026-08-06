import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/theme_controller.dart';

/// Library / bookshelf page (FEATURES §2).
///
/// Skeleton for M1: shows an empty-state guide (FEATURES 2.2) with an import
/// button placeholder. Real grid view, import, categories, favorites, and
/// search land in milestone M1.
class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.brightness_6_outlined),
            tooltip: '切换主题',
            onPressed: () => _toggleTheme(ref),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      body: _EmptyLibraryGuide(theme: theme),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('导入文档'),
        onPressed: () {
          // M1: file_picker multi-select -> copy to documents/ -> dedup -> insert
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('导入功能将在 M1 实现')),
          );
        },
      ),
    );
  }

  void _toggleTheme(WidgetRef ref) {
    final notifier = ref.read(themeControllerProvider.notifier);
    final current = ref.read(themeControllerProvider);
    notifier.set(
      current == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark,
    );
  }
}

/// Empty-state guide (FEATURES 2.2): explains supported formats + import entry.
class _EmptyLibraryGuide extends StatelessWidget {
  const _EmptyLibraryGuide({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined,
              size: 80, color: theme.colorScheme.outline),
          const SizedBox(height: 16),
          Text('书库为空', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '点击右下角「导入文档」添加 PDF 或图片',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '支持格式：PDF / PNG / JPG / WEBP / BMP / GIF / TIFF',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
