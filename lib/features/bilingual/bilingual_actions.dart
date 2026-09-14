import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_queue_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// 对照阅读 actions exposed in the reader toolbar while the bilingual view is
/// open (导出译文 PDF / 整本翻译). Kept out of the column widget: the spread has
/// no chrome of its own.

/// Streams the translated-PDF build and reports the output path.
Future<void> exportTranslatedPdf(
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

/// Whole-book translation: background-behavior dialog on first use, then a
/// confirmation with an estimate, then the queue starts.
Future<void> startWholeBookTranslation(
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
        '进行中可随时在右页下方取消；已翻译的页面会缓存。',
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
