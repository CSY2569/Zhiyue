import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/library/providers/library_providers.dart';

/// Top toolbar for the library page (FEATURES 2.7).
///
/// Hosts a debounced title search field plus the full-text search / theme /
/// settings actions. Filters (favorites / type / category) live exclusively
/// in the left rail, so they are not duplicated here; a small "clear
/// filters" affordance appears when a filter is active.
class LibraryToolbar extends ConsumerStatefulWidget implements PreferredSizeWidget {
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
  final _searchController = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    // Debounce 300ms so we don't run the filter on every keystroke.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      ref.read(libraryFilterProvider.notifier).setSearchQuery(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AppBar(
      titleSpacing: 8,
      title: SizedBox(
        width: 280,
        child: TextField(
          controller: _searchController,
          onChanged: _onSearchChanged,
          decoration: InputDecoration(
            hintText: '搜索书名…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 0),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHigh,
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _searchController.clear();
                      _onSearchChanged('');
                    },
                  )
                : null,
          ),
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.manage_search),
          tooltip: '全文搜索',
          onPressed: () => context.go('/search'),
        ),
        IconButton(
          icon: const Icon(Icons.brightness_6_outlined),
          tooltip: '切换主题',
          onPressed: widget.onToggleTheme,
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined),
          tooltip: '设置',
          onPressed: widget.onOpenSettings,
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
