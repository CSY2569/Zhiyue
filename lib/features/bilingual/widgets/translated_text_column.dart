import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/features/bilingual/providers/page_text_translation_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// The mobile bilingual column: the current page's blocks translated as text.
///
/// Unlike the desktop pane (which renders the RetainPDF engine's layout-
/// preserving PDF), this is a plain reading column: translation first, source
/// text collapsible, formulas kept verbatim. It fits a phone width and never
/// needs a Python sidecar.
class TranslatedTextColumn extends ConsumerWidget {
  const TranslatedTextColumn({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.watch(viewerProvider).currentPage;
    final key = (bookId: bookId, page: page);
    final state = ref.watch(pageTextTranslationProvider(key));

    return state.when(
      loading: () => const LoadingState(label: '正在提取页面文本…'),
      error: (e, _) => EmptyState(
        icon: LucideIcons.circleAlert,
        message: '$e',
        action: FilledButton(
          onPressed: () =>
              ref.read(pageTextTranslationProvider(key).notifier).translate(),
          child: const Text('重试'),
        ),
      ),
      data: (s) {
        final t = s.translation;
        if (s.error != null && t == null) {
          return _ErrorState(
            bookId: bookId,
            page: page,
            message: s.error!,
            canRetry: s.blocks == null || s.blocks!.blocks.isNotEmpty,
          );
        }
        if (t == null) {
          return _NotTranslated(
            bookId: bookId,
            page: page,
            blocks: s.blocks,
            loading: s.loading,
          );
        }
        return _BlockList(bookId: bookId, page: page, translation: t);
      },
    );
  }
}

class _ErrorState extends ConsumerWidget {
  const _ErrorState({
    required this.bookId,
    required this.page,
    required this.message,
    required this.canRetry,
  });

  final int bookId;
  final int page;
  final String message;
  final bool canRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EmptyState(
      icon: LucideIcons.languages,
      iconSize: 44,
      title: '翻译未完成',
      message: message,
      action: canRetry
          ? FilledButton(
              onPressed: () => ref
                  .read(pageTextTranslationProvider(
                          (bookId: bookId, page: page))
                      .notifier)
                  .translate(force: true),
              child: const Text('重试'),
            )
          : null,
    );
  }
}

/// Prompt shown before the page has been translated.
class _NotTranslated extends ConsumerWidget {
  const _NotTranslated({
    required this.bookId,
    required this.page,
    required this.blocks,
    required this.loading,
  });

  final int bookId;
  final int page;
  final PageTextBlocks? blocks;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blockCount = blocks?.blocks.length ?? 0;
    final none = blocks != null && blockCount == 0;
    return EmptyState(
      icon: LucideIcons.languages,
      iconSize: 44,
      title: none ? '本页没有可翻译的文字' : '第 $page 页',
      message: none
          ? '扫描页需要先完成 OCR，或在设置中启用自动 OCR。'
          : blocks == null
              ? '正在准备文本块…'
              : '共 $blockCount 个文本块，使用 AI 设置中的服务翻译为当前目标语言。',
      action: none
          ? null
          : FilledButton.icon(
              onPressed: () => ref
                  .read(pageTextTranslationProvider(
                          (bookId: bookId, page: page))
                      .notifier)
                  .translate(),
              icon: const Icon(LucideIcons.sparkles, size: 16),
              label: const Text('翻译本页'),
            ),
    );
  }
}

class _BlockList extends ConsumerWidget {
  const _BlockList({
    required this.bookId,
    required this.page,
    required this.translation,
  });

  final int bookId;
  final int page;
  final PageTextTranslation translation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final status = _statusLine(translation);
    final failed = translation.blocks
        .where((b) => b.status == TextBlockStatus.failed)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'p.$page · ${translation.targetLang}',
                  style: theme.textTheme.labelMedium,
                ),
              ),
              if (translation.cached)
                Text('已缓存', style: theme.textTheme.labelSmall),
              IconButton(
                tooltip: '重新翻译本页',
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                onPressed: () => ref
                    .read(pageTextTranslationProvider(
                            (bookId: bookId, page: page))
                        .notifier)
                    .translate(force: true),
              ),
            ],
          ),
        ),
        if (failed > 0)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '$failed 个文本块未翻译：${_firstError(translation) ?? '未知原因'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        if (status != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
            child: Text(status, style: theme.textTheme.labelSmall),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: translation.blocks.length,
            itemBuilder: (context, i) {
              final block = translation.blocks[i];
              return _BlockCard(
                key: ValueKey('text-translation-$page-${block.index}'),
                block: block,
              );
            },
          ),
        ),
      ],
    );
  }

  static String? _statusLine(PageTextTranslation t) {
    if (t.model.isEmpty) return null;
    return t.cached ? null : '模型：${t.model}';
  }

  static String? _firstError(PageTextTranslation t) {
    for (final b in t.blocks) {
      if (b.status == TextBlockStatus.failed && b.error != null) return b.error;
    }
    return null;
  }
}

/// One translated block: translation, then the source collapsed underneath
/// (expanded on tap). Headings keep their emphasis; formulas show the source
/// verbatim with a badge.
class _BlockCard extends StatefulWidget {
  const _BlockCard({super.key, required this.block});

  final TranslatedTextBlock block;

  @override
  State<_BlockCard> createState() => _BlockCardState();
}

class _BlockCardState extends State<_BlockCard> {
  bool _showSource = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final block = widget.block;
    final isHeading = block.subType == 'heading';
    final isFormula =
        block.kind == 'formula' || block.subType == 'display_formula';
    final isSkipped = block.status == TextBlockStatus.skipped;
    final failed = block.status == TextBlockStatus.failed;

    final textStyle = isHeading
        ? theme.textTheme.titleMedium
        : theme.textTheme.bodyMedium;
    final showText =
        isFormula || isSkipped ? block.sourceText : block.translatedText;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => setState(() => _showSource = !_showSource),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isFormula || isSkipped)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          isFormula ? '公式' : '原文',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              if (failed)
                Row(
                  children: [
                    Icon(LucideIcons.circleAlert,
                        size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        block.error ?? '翻译失败',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                )
              else
                Text(
                  showText,
                  style: textStyle?.copyWith(
                    fontFamily: isFormula ? 'monospace' : null,
                  ),
                ),
              if (!isFormula && !failed && block.sourceText.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  _showSource ? block.sourceText : '显示原文',
                  maxLines: _showSource ? 20 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
