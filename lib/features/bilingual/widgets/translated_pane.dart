import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_queue_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart'
    show kPageGap, pageHeightProvider;
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// The RIGHT "page" of the 对照 view (plan §5): a double-page-style spread —
/// the translated page is rendered at the SAME display size as the original
/// page beside it, on the shared reading background, scrolling in step with
/// it. No chrome of its own: the export / whole-book actions live in the
/// reader toolbar while 对照 is open.
class TranslatedColumn extends ConsumerWidget {
  const TranslatedColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(viewerProvider);
    final bookId = viewer.book?.id;
    final targetLang =
        ref.watch(aiConfigProvider).valueOrNull?.translateTargetLang ??
            '中文';
    final configured = _isConfigured(ref);
    final configLoading = ref.watch(translationConfigProvider).isLoading;
    final queue = ref.watch(translationQueueProvider);

    Widget body;
    if (configLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!configured) {
      body = _NotConfigured(onGoSettings: () => _openSettings(context));
    } else if (bookId == null) {
      body = const Center(
        child: Text('打开一本书后即可对照阅读',
            style: TextStyle(color: Colors.black38)),
      );
    } else {
      // Same display size as the original page (physical height x zoom), so
      // left and right read as two pages of one spread.
      final displayH =
          ref.watch(pageHeightProvider) * viewer.zoom.clamp(0.3, 4.0);
      body = _SyncedPageList(
        bookId: bookId,
        currentPage: viewer.currentPage,
        pageCount: viewer.pageCount,
        targetLang: targetLang,
        displayH: displayH,
        itemExtent: displayH + kPageGap,
      );
    }

    return Stack(
      children: [
        body,
        if (queue.running && queue.totalPages > 0)
          Positioned(
            left: 16,
            right: 16,
            bottom: 12,
            child: _QueuePill(queue: queue),
          ),
      ],
    );
  }

  /// Whether a usable translation service exists: reuse-AI needs the AI
  /// config, the other two need their own key (plan §5 空态引导).
  bool _isConfigured(WidgetRef ref) {
    final tc = ref.watch(translationConfigProvider).valueOrNull;
    if (tc == null) return false;
    switch (tc.provider) {
      case TranslationProviderKind.deepL:
      case TranslationProviderKind.openAiCompat:
        return (tc.apiKey?.trim() ?? '').isNotEmpty;
      case TranslationProviderKind.reuseAi:
        final ai = ref.watch(aiConfigProvider).valueOrNull;
        return (ai?.apiKey.trim().isNotEmpty ?? false) &&
            (ai?.textModel.trim().isNotEmpty ?? false);
    }
  }

  void _openSettings(BuildContext context) {
    GoRouter.of(context).push('/settings');
  }
}

/// Page list synced to the original's current page: page N lives at offset
/// (N-1) x itemExtent — the same stride model as [PdfPageScroll] — so a page
/// turn jumps the column to the matching "page of the spread".
class _SyncedPageList extends ConsumerStatefulWidget {
  const _SyncedPageList({
    required this.bookId,
    required this.currentPage,
    required this.pageCount,
    required this.targetLang,
    required this.displayH,
    required this.itemExtent,
  });

  final int bookId;
  final int currentPage;
  final int pageCount;
  final String targetLang;
  final double displayH;
  final double itemExtent;

  @override
  ConsumerState<_SyncedPageList> createState() => _SyncedPageListState();
}

class _SyncedPageListState extends ConsumerState<_SyncedPageList> {
  late final _controller = ScrollController(
    initialScrollOffset: (widget.currentPage - 1).clamp(0, 1 << 30) *
        widget.itemExtent,
  );
  int _syncedPage = 0;

  @override
  void initState() {
    super.initState();
    _syncedPage = widget.currentPage;
  }

  @override
  void didUpdateWidget(covariant _SyncedPageList old) {
    super.didUpdateWidget(old);
    if (widget.currentPage != _syncedPage && widget.currentPage >= 1) {
      _syncedPage = widget.currentPage;
      _jumpTo(_syncedPage);
    }
    if (widget.itemExtent != old.itemExtent) {
      // The stride changed (zoom / first real page height): re-align.
      _jumpTo(_syncedPage);
    }
  }

  void _jumpTo(int page) {
    if (!_controller.hasClients) return;
    final max = _controller.position.maxScrollExtent;
    _controller.jumpTo(
      ((page - 1) * widget.itemExtent).clamp(0.0, max),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: _controller,
      itemExtent: widget.itemExtent,
      itemCount: widget.pageCount,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: kPageGap),
        child: Align(
          child: _TranslatedPageCard(
            key: ValueKey(i + 1),
            bookId: widget.bookId,
            page: i + 1,
            targetLang: widget.targetLang,
            displayH: widget.displayH,
          ),
        ),
      ),
    );
  }
}

/// One translated page drawn as a "paper" sheet matching the original page's
/// display size, with a small page chip for orientation.
class _TranslatedPageCard extends ConsumerWidget {
  const _TranslatedPageCard({
    super.key,
    required this.bookId,
    required this.page,
    required this.targetLang,
    required this.displayH,
  });

  final int bookId;
  final int page;
  final String targetLang;
  final double displayH;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(translatedPageImageProvider(
      (bookId: bookId, page: page, targetLang: targetLang),
    ));
    final state = async.valueOrNull;
    final pageState = ref
        .watch(pageTranslationProvider((bookId: bookId, page: page)))
        .valueOrNull;
    final translating = pageState?.loading ?? false;

    final image = state?.image;
    final hasTranslation = state?.hasTranslation ?? false;
    final error = state?.error ?? pageState?.error;

    // Same aspect as the original page (identical page geometry); fall back
    // to A4 while the bitmap renders.
    final aspect = (image != null && image.height > 0)
        ? image.width / image.height
        : 1 / 1.414;
    final displayW = (displayH * aspect).clamp(80.0, 1600.0);

    return SizedBox(
      width: displayW,
      height: displayH,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: image != null
                ? RawImage(image: image, fit: BoxFit.fill)
                : _PagePlaceholder(
                    page: page,
                    translating: translating,
                    hasTranslation: hasTranslation,
                    onTranslate: () => ref
                        .read(pageTranslationProvider(
                                (bookId: bookId, page: page))
                            .notifier)
                        .translate(),
                  ),
          ),
          // Page chip (orientation + test handle).
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.85),
                borderRadius:
                    const BorderRadius.only(bottomRight: Radius.circular(6)),
              ),
              child: Text(
                'p.$page',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
          // Re-translate affordance for translated pages.
          if (hasTranslation && !translating)
            Positioned(
              right: 0,
              top: 0,
              child: IconButton(
                icon: Icon(Icons.refresh,
                    size: 16, color: theme.colorScheme.outline),
                tooltip: '重新翻译本页',
                onPressed: () => ref
                    .read(pageTranslationProvider(
                            (bookId: bookId, page: page))
                        .notifier)
                    .translate(force: true),
              ),
            ),
          if (error != null)
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Text(
                error,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _PagePlaceholder extends StatelessWidget {
  const _PagePlaceholder({
    required this.page,
    required this.translating,
    required this.hasTranslation,
    required this.onTranslate,
  });

  final int page;
  final bool translating;
  final bool hasTranslation;
  final VoidCallback onTranslate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (translating) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.translate, size: 32, color: theme.colorScheme.outline),
            const SizedBox(height: 10),
            Text(
              hasTranslation ? '译文渲染中…' : '本页尚未翻译',
              style: theme.textTheme.titleSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              '点击「翻译本页」，或在设置中选择自动翻译方式',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onTranslate,
              icon: const Icon(Icons.translate, size: 16),
              label: const Text('翻译本页'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact floating whole-book progress (整本 x/N · 取消) while a run is active.
class _QueuePill extends ConsumerWidget {
  const _QueuePill({required this.queue});
  final TranslationQueueState queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '整本翻译 ${queue.donePages}/${queue.totalPages} 页',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 80,
            child: LinearProgressIndicator(
                value: queue.progress, minHeight: 4),
          ),
          TextButton(
            style:
                TextButton.styleFrom(visualDensity: VisualDensity.compact),
            onPressed: () =>
                ref.read(translationQueueProvider.notifier).cancel(),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}

class _NotConfigured extends StatelessWidget {
  const _NotConfigured({required this.onGoSettings});
  final VoidCallback onGoSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 40),
            const SizedBox(height: 10),
            Text('未配置翻译服务', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(
              '在「设置 → 对照阅读」中选择翻译服务并填写 API Key',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onGoSettings,
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('去设置'),
            ),
          ],
        ),
      ),
    );
  }
}
