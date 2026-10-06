import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/bilingual/providers/engine_provider.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// 「翻译引擎」 settings card.
///
/// The engine is the RetainPDF pipeline (`retainpdf-pipeline`, MIT), shipped
/// INSIDE the installation bundle: there is no download and no in-app
/// uninstall. The card reports the on-disk state (version + footprint) or,
/// for development builds without an assembled engine, the build-time hint.
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
                if (status != null) _StatusChip(kind: kind, bundled: status.bundled),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '对照阅读由 RetainPDF 翻译引擎驱动（内置组件，MIT 开源；'
              '翻译与排版在独立进程中运行）。译文固定为简体中文。',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            switch (kind) {
              EngineStatusKind.installed => Text(
                  '${status!.bundled ? '已内置（随安装包分发）' : '已就绪'}'
                  '${status.version.isNotEmpty ? ' · ${status.version}' : ''}'
                  '${status.sizeBytes > 0 ? ' · 占用 ${_formatBytes(status.sizeBytes)}' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
              _ => Text(
                  '未找到翻译引擎。正式安装包内置该引擎；'
                  '开发构建请先运行 scripts/build_retain_engine.sh，'
                  '并设置 RBWA_RETAIN_ENGINE_DIR 指向组装目录。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
            },
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.kind, required this.bundled});

  final EngineStatusKind kind;
  final bool bundled;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (kind) {
      EngineStatusKind.installed => (bundled ? '已内置' : '已就绪', Colors.green),
      EngineStatusKind.installing => ('安装中', Colors.blue),
      EngineStatusKind.failed => ('失败', Colors.red),
      EngineStatusKind.notInstalled => ('未找到', Colors.grey),
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