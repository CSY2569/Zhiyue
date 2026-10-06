import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/bilingual/providers/book_translation_provider.dart';
import 'package:rbwa/features/bilingual/providers/engine_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/pdf_page_scroll.dart'
    show kPageGap, pageHeightProvider;
import 'package:rbwa/src/rust/models/translate.dart';

/// The RIGHT "page" of the 对照 view: a double-page-style spread — the
/// translated page renders at the SAME display size as the original page
/// beside it, scrolling in step with it.
///
/// Three states: engine missing (download guide), engine ready without an
/// artifact (translate action + progress), artifact present (page-by-page
/// rendering of the engine's mono PDF).
class TranslatedColumn extends ConsumerWidget {
  const TranslatedColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(viewerProvider);
    final bookId = viewer.book?.id;
    final engine = ref.watch(engineStatusProvider).valueOrNull;
    final engineReady = engine?.kind == EngineStatusKind.installed;

    final Widget body;
    if (bookId == null) {
      body = const Center(
        child: Text('打开一本书后即可对照阅读',
            style: TextStyle(color: Colors.black38)),
      );
    } else if (!engineReady) {
      body = const _EngineNotice();
    } else {
      final state = ref.watch(bookTranslationProvider(bookId));
      final t = state.valueOrNull;
      if (t == null || !t.loaded) {
        body = const Center(child: CircularProgressIndicator());
      } else if (!t.hasArtifact) {
        body = _TranslateReady(
          bookId: bookId,
          state: t,
          onTranslate: () =>
              ref.read(bookTranslationProvider(bookId).notifier).translate(),
          onCancel: () =>
              ref.read(bookTranslationProvider(bookId).notifier).cancel(),
        );
      } else {
        final displayH =
            ref.watch(pageHeightProvider) * viewer.zoom.clamp(0.3, 4.0);
        body = _SyncedPageList(
          bookId: bookId,
          currentPage: viewer.currentPage,
          displayH: displayH,
          itemExtent: displayH + kPageGap,
          translation: t.translation!,
          onRetranslate: () =>
              ref.read(bookTranslationProvider(bookId).notifier).translate(),
          onClear: () =>
              ref.read(bookTranslationProvider(bookId).notifier).clear(),
        );
      }
    }

    return Stack(children: [body]);
  }
}

/// Engine state placeholder: the embedded translation engine is a separate,
/// user-approved download (about 1.5GB) unless the build ships one.
class _EngineNotice extends StatelessWidget {
  const _EngineNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate_outlined,
                  size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('未找到翻译引擎', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '对照阅读由内置的 RetainPDF 引擎驱动；'
                '正式安装包已内置该引擎，开发构建需先组装引擎目录后才能翻译。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: () => GoRouter.of(context).push('/settings'),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: const Text('前往设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Engine ready, no artifact yet: explain + start the whole-book run.
class _TranslateReady extends StatelessWidget {
  const _TranslateReady({
    required this.bookId,
    required this.state,
    required this.onTranslate,
    required this.onCancel,
  });

  final int bookId;
  final BookTranslationState state;
  final VoidCallback onTranslate;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (state.running) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(state.phase, style: theme.textTheme.titleSmall),
                if (state.detail.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    state.detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
                const SizedBox(height: 12),
                OutlinedButton(onPressed: onCancel, child: const Text('取消翻译')),
              ],
            ),
          ),
        ),
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.translate, size: 40, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text('翻译本书', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '引擎将整本翻译并保留原版式（图表、公式、页码原样保留）。'
                '完成后本栏按页显示译文，导出同版式的双语 PDF。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (state.error != null) ...[
                const SizedBox(height: 10),
                Text(state.error!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onTranslate,
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('开始翻译'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page list synced to the original's current page: page N lives at offset
/// (N-1) x itemExtent -- the same stride model as [PdfPageScroll] -- so a
/// page turn jumps the column to the matching "page of the spread".
class _SyncedPageList extends StatefulWidget {
  const _SyncedPageList({
    required this.bookId,
    required this.currentPage,
    required this.displayH,
    required this.itemExtent,
    required this.translation,
    required this.onRetranslate,
    required this.onClear,
  });

  final int bookId;
  final int currentPage;
  final double displayH;
  final double itemExtent;
  final BookTranslation translation;
  final VoidCallback onRetranslate;
  final VoidCallback onClear;

  @override
  State<_SyncedPageList> createState() => _SyncedPageListState();
}

class _SyncedPageListState extends State<_SyncedPageList> {
  late final _controller = ScrollController(
    initialScrollOffset:
        (widget.currentPage - 1).clamp(0, 1 << 30) * widget.itemExtent,
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
      _jumpTo(_syncedPage);
    }
  }

  void _jumpTo(int page) {
    if (!_controller.hasClients) return;
    final target = (page - 1).clamp(0, 1 << 30) * widget.itemExtent;
    _controller.jumpTo(target.clamp(
      0.0,
      _controller.position.maxScrollExtent,
    ));
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
      itemCount: widget.translation.pages,
      itemBuilder: (context, index) => _TranslatedPageCard(
        bookId: widget.bookId,
        page: index + 1,
        displayH: widget.displayH,
        onRetranslate: widget.onRetranslate,
        onClear: widget.onClear,
        langLabel: widget.translation.targetLang,
      ),
    );
  }
}

class _TranslatedPageCard extends ConsumerWidget {
  const _TranslatedPageCard({
    required this.bookId,
    required this.page,
    required this.displayH,
    required this.onRetranslate,
    required this.onClear,
    required this.langLabel,
  });

  final int bookId;
  final int page;
  final double displayH;
  final VoidCallback onRetranslate;
  final VoidCallback onClear;
  final String langLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(
        translatedPageImageProvider((bookId: bookId, page: page)));
    final data = async.valueOrNull;

    return Padding(
      padding: EdgeInsets.only(bottom: kPageGap - 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const SizedBox(width: 4),
              Text('p.$page',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const Spacer(),
              Text(langLabel,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              PopupMenuButton<String>(
                tooltip: '译本操作',
                iconSize: 16,
                onSelected: (v) =>
                    v == 'again' ? onRetranslate() : onClear(),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 'again', child: Text('重新翻译')),
                  PopupMenuItem(value: 'clear', child: Text('删除译本')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Container(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2)),
                ],
              ),
              child: _pageContent(theme, data),
            ),
          ),
        ],
      ),
    );
  }

  Widget _pageContent(ThemeData theme, TranslatedPageImage? data) {
    if (data == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (data.image != null) {
      return RawImage(
        image: data.image,
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
      );
    }
    return Center(
      child: Text(
        data.error ?? '该页暂无译文',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.outline),
      ),
    );
  }
}