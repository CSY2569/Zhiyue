import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/reader/providers/thumbnail_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';

/// Thumbnail sidebar (FEATURES 3.4.1).
///
/// Each tile renders its page once (via [ThumbnailCache]) and reuses the
/// cached bitmap on re-open / scroll-back, so the rail stays fast. The
/// current page is highlighted; tapping a thumbnail jumps to it.
class ThumbnailRail extends ConsumerStatefulWidget {
  const ThumbnailRail({super.key, required this.onJump});

  /// Called when the user taps a thumbnail; the page (0-indexed) is passed.
  final void Function(int page) onJump;

  @override
  ConsumerState<ThumbnailRail> createState() => _ThumbnailRailState();
}

class _ThumbnailRailState extends ConsumerState<ThumbnailRail> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(viewerProvider);
    final theme = Theme.of(context);

    return SizedBox(
      width: 180,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: state.pageCount == 0
            ? const Center(child: Text('无页面'))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: state.pageCount,
                itemBuilder: (context, index) {
                  final isCurrent = index == state.currentPage - 1;
                  return _ThumbnailTile(
                    bookId: state.book?.id ?? 0,
                    page: index,
                    pageNumber: index + 1,
                    isCurrent: isCurrent,
                    onTap: () => widget.onJump(index),
                  );
                },
              ),
      ),
    );
  }
}

class _ThumbnailTile extends ConsumerStatefulWidget {
  const _ThumbnailTile({
    required this.bookId,
    required this.page,
    required this.pageNumber,
    required this.isCurrent,
    required this.onTap,
  });

  final int bookId;
  final int page;
  final int pageNumber;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  ConsumerState<_ThumbnailTile> createState() => _ThumbnailTileState();
}

class _ThumbnailTileState extends ConsumerState<_ThumbnailTile> {
  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void didUpdateWidget(_ThumbnailTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.page != widget.page || oldWidget.bookId != widget.bookId) {
      _fetch();
    }
  }

  /// Request the thumbnail; the cache update rebuilds this tile once the
  /// bitmap is decoded. Runs post-frame so it never mutates providers during
  /// build.
  void _fetch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(thumbnailCacheProvider.notifier)
          .getOrFetch(widget.bookId, widget.page);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final image =
        ref.watch(thumbnailCacheProvider.select((m) => m[widget.page]));

    return InkWell(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          border: Border.all(
            color: widget.isCurrent
                ? theme.colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 120,
              child: image == null
                  ? Center(
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    )
                  : RawImage(image: image, fit: BoxFit.contain),
            ),
            const SizedBox(height: 4),
            Text(
              '${widget.pageNumber}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: widget.isCurrent
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight:
                    widget.isCurrent ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
