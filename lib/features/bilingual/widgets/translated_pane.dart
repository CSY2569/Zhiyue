import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/page_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/translated_page_image_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_queue_provider.dart';
import 'package:rbwa/features/reader/providers/panel_layout.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/progress.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// The bilingual-reading pane (对照阅读, plan §5).
///
/// The translation is shown as a real PDF **page** beside the original
/// document (same page size, selectable text, embedded formula images),
/// rather than a list of paragraphs: [translatedPageImageProvider] renders the
/// page's translation through Rust (single-page PDF -> RGBA) and this pane
/// draws it scaled to the pane width. Double-page modes stack both visible
/// pages.
class TranslatedPane extends ConsumerWidget {
  const TranslatedPane({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final width =
        ref.watch(panelLayoutProvider.select((p) => p.translatedPaneWidth));
    final viewer = ref.watch(viewerProvider);
    final bookId = viewer.book?.id;
    final targetLang = ref
            .watch(aiConfigProvider)
            .valueOrNull
            ?.translateTargetLang ??
        '中文';
    final configured = _isConfigured(ref);
    final configLoading = ref.watch(translationConfigProvider).isLoading;
    final queue = ref.watch(translationQueueProvider);

    return SizedBox(
      width: width,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            _Header(
              bookId: bookId,
              page: viewer.currentPage,
              targetLang: targetLang,
              configured: configured,
            ),
            if (queue.running && queue.totalPages > 0)
              _QueueProgressBar(queue: queue),
            const Divider(height: 1),
            Expanded(
              // While the config is still loading, do NOT claim "not
              // configured" -- that flashed a misleading guide on every open.
              child: configLoading
                  ? const Center(child: CircularProgressIndicator())
                  : !configured
                      ? _NotConfigured(
                          onGoSettings: () => _openSettings(context))
                      : bookId == null
                          ? const EmptyState(
                              icon: Icons.translate,
                              title: '未打开书籍',
                              message: '打开一本书后即可对照阅读',
                            )
                          : _PageList(
                              bookId: bookId,
                              mode: viewer.mode,
                              currentPage: viewer.currentPage,
                              pageCount: viewer.pageCount,
                              targetLang: targetLang,
                            ),
            ),
          ],
        ),
      ),
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

class _Header extends ConsumerWidget {
  const _Header({
    required this.bookId,
    required this.page,
    required this.targetLang,
    required this.configured,
  });

  final int? bookId;
  final int page;
  final String targetLang;
  final bool configured;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.translate, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '对照阅读',
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Chip(
                label: Text(targetLang, style: theme.textTheme.labelSmall),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const Spacer(),
              if (configured && bookId != null) ...[
                IconButton(
                  icon: const Icon(Icons.picture_as_pdf_outlined, size: 18),
                  tooltip: '导出译文 PDF',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _exportPdf(context, ref, bookId!, targetLang),
                ),
                IconButton(
                  icon: const Icon(Icons.download_done_outlined, size: 18),
                  tooltip: '整本翻译',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _startWholeBook(context, ref, bookId!),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '关闭对照阅读',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      ref.read(translationPaneProvider.notifier).close(),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _startWholeBook(
    BuildContext context,
    WidgetRef ref,
    int bookId,
  ) async {
    final config = ref.read(translationConfigProvider).valueOrNull;
    final pageCount = ref.read(viewerProvider).pageCount;
    if (config == null || pageCount == 0) return;

    var behavior = config.backgroundBehavior;
    if (behavior == TranslationBackgroundBehavior.ask) {
      final chosen = await showDialog<TranslationBackgroundBehavior>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('整本翻译后台行为'),
          content: const Text('整本翻译进行中切换到其他书籍时：'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(
                  ctx, TranslationBackgroundBehavior.pauseResume),
              child: const Text('切书暂停，回来续传'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, TranslationBackgroundBehavior.continue_),
              child: const Text('后台继续'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, TranslationBackgroundBehavior.cancel),
              child: const Text('离开即取消'),
            ),
          ],
        ),
      );
      if (chosen == null) return;
      behavior = chosen;
      await ref
          .read(translationConfigProvider.notifier)
          .setBackgroundBehavior(chosen);
    }

    if (!context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('整本翻译'),
        content: Text(
          '将翻译全书 $pageCount 页。\n\n'
          '预计耗时约 ${(pageCount * 4 / 60).ceil()} 分钟（依服务与网络浮动）。\n'
          'DeepL 免费版每月 50 万字符额度，LLM 按 token 计费。\n\n'
          '进行中可随时在右栏取消；已翻译的页面会缓存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始翻译'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref
        .read(translationQueueProvider.notifier)
        .startBook(bookId: bookId, totalPages: pageCount);
  }

  Future<void> _exportPdf(
    BuildContext context,
    WidgetRef ref,
    int bookId,
    String targetLang,
  ) async {
    final repo = ref.read(translationRepositoryProvider);
    final messenger = ScaffoldMessenger.maybeOf(context);
    var done = 0;
    var total = 0;
    try {
      await for (final ev in repo.buildTranslatedPdf(
        bookId: bookId,
        targetLang: targetLang,
      )) {
        done = ev.doneParagraphs;
        total = ev.totalParagraphs;
      }
    } catch (e) {
      messenger?.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      return;
    }
    final path = await repo.translatedPdfPath(
      bookId: bookId,
      targetLang: targetLang,
    );
    if (!context.mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text('已生成译文 PDF（$done/$total 页）：$path'),
        action: SnackBarAction(
          label: '复制路径',
          onPressed: () => Clipboard.setData(ClipboardData(text: path)),
        ),
      ),
    );
  }
}

/// Whole-book progress header (plan §5): 已完成 x/N · 预计剩余 + 取消.
class _QueueProgressBar extends ConsumerWidget {
  const _QueueProgressBar({required this.queue});
  final TranslationQueueState queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final remaining = queue.estimatedRemaining;
    final remainingText =
        remaining == null ? '' : ' · 预计剩余 ~${remaining.inMinutes} 分钟';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '已完成 ${queue.donePages}/${queue.totalPages} 页$remainingText',
                  style: theme.textTheme.labelSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
          LinearProgressIndicator(value: queue.progress, minHeight: 3),
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
    return EmptyState(
      icon: Icons.cloud_off_outlined,
      title: '未配置翻译服务',
      message: '在「设置 → 对照阅读」中选择翻译服务并填写 API Key',
      action: FilledButton.icon(
        onPressed: onGoSettings,
        icon: const Icon(Icons.settings_outlined, size: 18),
        label: const Text('去设置'),
      ),
    );
  }
}

/// The visible translated pages, one card per page.
class _PageList extends ConsumerWidget {
  const _PageList({
    required this.bookId,
    required this.mode,
    required this.currentPage,
    required this.pageCount,
    required this.targetLang,
  });

  final int bookId;
  final ViewMode mode;
  final int currentPage;
  final int pageCount;
  final String targetLang;

  List<int> get _visible {
    if (mode == ViewMode.single) return [currentPage];
    final right = currentPage + 1;
    return right <= pageCount ? [currentPage, right] : [currentPage];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pages = _visible;
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: pages.length,
          itemBuilder: (context, i) => _TranslatedPageCard(
            key: ValueKey(pages[i]),
            bookId: bookId,
            page: pages[i],
            targetLang: targetLang,
            availableWidth: constraints.maxWidth - 24,
          ),
        );
      },
    );
  }
}

/// One page: the rendered translation drawn as a PDF page, with an overlay
/// label and (when untranslated) a placeholder + 翻译本页 action.
class _TranslatedPageCard extends ConsumerWidget {
  const _TranslatedPageCard({
    super.key,
    required this.bookId,
    required this.page,
    required this.targetLang,
    required this.availableWidth,
  });

  final int bookId;
  final int page;
  final String targetLang;
  final double availableWidth;

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

    // Aspect ratio from the rendered page (fall back to A4).
    final aspect = (image != null && image.width > 0)
        ? image.height / image.width
        : 1.414;
    final displayW = availableWidth.clamp(120.0, 1200.0);
    final displayH = displayW * aspect;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Page anchor + status/action row (plan §2: p.N 定位锚点).
          Row(
            children: [
              Text(
                '译文 p.$page',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (translating)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  onPressed: () => ref
                      .read(pageTranslationProvider(
                              (bookId: bookId, page: page))
                          .notifier)
                      .translate(force: hasTranslation),
                  child: Text(hasTranslation ? '重新翻译' : '翻译本页'),
                ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          // The page itself: a bordered "paper" card sized like the original.
          Container(
            width: displayW,
            height: displayH,
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: theme.colorScheme.outlineVariant),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: image != null
                ? RawImage(image: image, fit: BoxFit.fill)
                : _PagePlaceholder(
                    translating: translating,
                    hasTranslation: hasTranslation,
                    onTranslate: () => ref
                        .read(pageTranslationProvider(
                                (bookId: bookId, page: page))
                            .notifier)
                        .translate(),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PagePlaceholder extends StatelessWidget {
  const _PagePlaceholder({
    required this.translating,
    required this.hasTranslation,
    required this.onTranslate,
  });

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
