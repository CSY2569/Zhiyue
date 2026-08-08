import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/reader/providers/scan_provider.dart';

/// Scan prompt card (FEATURES 7.1.2 / FLUTTER_UI_MIGRATION §6.5): a slim bar
/// anchored to the page's top-left corner. Each page hosts one instance and
/// renders its own scan state (per-page, so both halves of a spread get
/// their prompt and can be scanned independently); pages with a native text
/// layer render nothing. Walks the state machine (prompt -> scanning ->
/// success / empty / error).
class ScanOverlay extends ConsumerWidget {
  const ScanOverlay({super.key, required this.page});

  /// The hosting page, 0-indexed (matches the page stack's [widget.page]).
  final int page;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanStateProvider);
    final state = scan.of(page);
    if (state == null || state.phase == ScanPhase.hasText) {
      return const SizedBox.shrink();
    }
    final notifier = ref.read(scanStateProvider.notifier);
    final theme = Theme.of(context);

    switch (state.phase) {
      case ScanPhase.hasText:
        return const SizedBox.shrink();
      case ScanPhase.dismissed:
        return const SizedBox.shrink();
      case ScanPhase.prompt:
        return _bar(
          theme,
          icon: Icons.document_scanner_outlined,
          text: '本页没有文本层，可整页扫描识别后选中 / 标记',
          actions: [
            TextButton(
              onPressed: () => notifier.scan(page),
              child: const Text('扫描识别'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '关闭提示',
              visualDensity: VisualDensity.compact,
              onPressed: () => notifier.dismiss(page),
            ),
          ],
        );
      case ScanPhase.scanning:
        return _bar(
          theme,
          icon: Icons.document_scanner_outlined,
          text: '正在识别…',
          actions: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        );
      case ScanPhase.success:
        return _bar(
          theme,
          icon: Icons.check_circle_outline,
          text: state.lowConfidence > 0
              ? '识别完成，本页文字现在可以选中和标记了。'
                  '${state.lowConfidence} 行置信度较低，建议对照原文复核'
              : '识别完成，本页文字现在可以选中和标记了',
          actions: [
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '关闭提示',
              visualDensity: VisualDensity.compact,
              onPressed: () => notifier.dismiss(page),
            ),
          ],
        );
      case ScanPhase.empty:
        return _bar(
          theme,
          icon: Icons.info_outline,
          text: '未识别到文字。数学 / 外语区域可使用「识图」框选处理',
          actions: [
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '关闭提示',
              visualDensity: VisualDensity.compact,
              onPressed: () => notifier.dismiss(page),
            ),
          ],
        );
      case ScanPhase.error:
        return _bar(
          theme,
          icon: Icons.error_outline,
          text: state.error ?? '扫描失败',
          actions: [
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: '关闭提示',
              visualDensity: VisualDensity.compact,
              onPressed: () => notifier.dismiss(page),
            ),
          ],
        );
    }
  }

  Widget _bar(ThemeData theme,
      {required IconData icon, required String text, required List<Widget> actions}) {
    return Material(
      elevation: 2,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                text,
                style: theme.textTheme.bodySmall,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            ...actions,
          ],
        ),
      ),
    );
  }
}
