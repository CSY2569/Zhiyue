import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/widgets/search_field.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';

/// Top toolbar for the library page (FEATURES 2.7).
///
/// Hosts a debounced title search field plus the full-text search / theme /
/// settings actions. Filters (favorites / type / category) live exclusively
/// in the left rail, so they are not duplicated here; a small "clear
/// filters" affordance appears when a filter is active.
class LibraryToolbar extends ConsumerStatefulWidget
    implements PreferredSizeWidget {
  const LibraryToolbar({
    super.key,
    required this.onToggleTheme,
    required this.onOpenSettings,
  });

  final VoidCallback onToggleTheme;
  final VoidCallback onOpenSettings;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  ConsumerState<LibraryToolbar> createState() => _LibraryToolbarState();
}

class _LibraryToolbarState extends ConsumerState<LibraryToolbar> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppBar(
      titleSpacing: 8,
      title: SizedBox(
        width: 280,
        child: DebouncedSearchField(
          hint: '搜索书名…',
          pill: true,
          fillColor: theme.colorScheme.surfaceContainerHigh,
          onChanged: (value) =>
              ref.read(libraryFilterProvider.notifier).setSearchQuery(value),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(LucideIcons.fileSearch),
          tooltip: '全文搜索',
          onPressed: () => context.go('/search'),
        ),
        IconButton(
          icon: const Icon(LucideIcons.sunMoon),
          tooltip: '切换主题',
          onPressed: widget.onToggleTheme,
        ),
        IconButton(
          icon: const Icon(LucideIcons.settings),
          tooltip: '设置',
          onPressed: widget.onOpenSettings,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
