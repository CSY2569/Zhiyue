import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/reader/providers/viewer_provider.dart';

/// The RIGHT "page" of the 对照 view: a double-page-style spread — the
/// translated page renders at the SAME display size as the original page
/// beside it, scrolling in step with it.
///
/// The built-in renderer was retired together with the translation pipeline;
/// the column now shows the engine state (not installed → download prompt in
/// settings) and will render BabelDOC output once the engine integration
/// lands. No chrome of its own: the reader toolbar owns the 对照 toggle.
class TranslatedColumn extends ConsumerWidget {
  const TranslatedColumn({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(viewerProvider);
    final bookId = viewer.book?.id;

    final Widget body;
    if (bookId == null) {
      body = const Center(
        child: Text('打开一本书后即可对照阅读',
            style: TextStyle(color: Colors.black38)),
      );
    } else {
      body = const _EngineNotice();
    }

    return Stack(
      children: [body],
    );
  }
}

/// Engine state placeholder: the embedded translation engine is a separate,
/// user-approved download (about 1GB); this is the entry point until the
/// engine integration wires the real status + install progress here.
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
              Icon(Icons.cloud_download_outlined,
                  size: 44, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('尚未安装翻译引擎', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(
                '对照阅读由 BabelDOC 引擎驱动（独立开源组件，AGPL-3.0，'
                '约 1GB）。可在设置中下载并启用；安装完成后译文将在此显示。',
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