import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/bilingual/providers/engine_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// 「翻译引擎」 settings card: the opt-in BabelDOC download.
///
/// The engine is a separate open-source component (AGPL-3.0) about 1.5GB in
/// size, installed into the app data directory on request; nothing ships in
/// the app bundle. Translation features stay dormant until it is installed.
class EngineSettingsCard extends ConsumerWidget {
  const EngineSettingsCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(engineStatusProvider);
    final status = async.valueOrNull;
    final kind = status?.kind ?? EngineStatusKind.notInstalled;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.translate, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('翻译引擎', style: theme.textTheme.titleSmall),
                const Spacer(),
                if (status != null) _StatusChip(kind: kind),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '对照阅读由 BabelDOC 开源引擎驱动（独立组件，AGPL-3.0）。'
              '引擎不随应用分发，首次启用需下载约 1.5GB（Python 环境 + 模型资产）。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            if (kind == EngineStatusKind.installing) ...[
              LinearProgressIndicator(value: status!.progress > 0 ? status.progress : null),
              const SizedBox(height: 6),
              Text(
                '${status.phase}${status.progress > 0 ? '（${(status.progress * 100).round()}%）' : ''}',
                style: theme.textTheme.bodySmall,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () =>
                      ref.read(engineStatusProvider.notifier).cancel(),
                  child: const Text('取消'),
                ),
              ),
            ] else ...[
              Row(
                children: [
                  Switch(
                    value: kind == EngineStatusKind.installed,
                    onChanged: (on) => on
                        ? _confirmInstall(context, ref)
                        : _confirmUninstall(context, ref),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      switch (kind) {
                        EngineStatusKind.installed =>
                          '已启用${status!.version.isNotEmpty ? '（v${status.version}）' : ''}'
                              '${status.sizeBytes > 0 ? ' · 占用 ${_formatBytes(status.sizeBytes)}' : ''}',
                        EngineStatusKind.failed =>
                          '安装失败：${status?.error ?? '未知错误'}',
                        _ => '未启用',
                      },
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  if (kind == EngineStatusKind.failed)
                    TextButton(
                      onPressed: () =>
                          ref.read(engineStatusProvider.notifier).install(),
                      child: const Text('重试'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmInstall(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('下载翻译引擎'),
        content: const Text(
          '将下载并安装 BabelDOC 翻译引擎：\n\n'
          '• 体积约 1.5GB（Python 运行时经 uv 管理，模型资产下载自公开镜像）\n'
          '• 安装位置为应用数据目录，可随时在此卸载\n'
          '• BabelDOC 为 AGPL-3.0 开源组件，与本应用独立运行\n\n'
          '安装需要网络连接，耗时取决于网速。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始下载'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(engineStatusProvider.notifier).install();
    }
  }

  Future<void> _confirmUninstall(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载翻译引擎'),
        content: const Text(
          '将删除已下载的引擎环境与模型资产（约 1.5GB）。\n'
          '已翻译的书籍产物不受影响；再次使用需重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(engineStatusProvider.notifier).uninstall();
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.kind});

  final EngineStatusKind kind;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      EngineStatusKind.installed => ('已安装', Colors.green),
      EngineStatusKind.installing => ('安装中', Colors.blue),
      EngineStatusKind.failed => ('失败', Colors.red),
      EngineStatusKind.notInstalled => ('未安装', Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 || unit == 0 ? 0 : 1)} ${units[unit]}';
}