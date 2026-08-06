import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/theme_controller.dart';

/// Settings page (FEATURES §6.1, §8.2).
///
/// Skeleton form with placeholders for: AI config (BYOK), translation target,
/// web search toggle, OCR mode, and theme. Real persistence + validation
/// lands in M1 (theme) and M4 (AI config).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeControllerProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/library'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle('主题', theme),
          ListTile(
            leading: const Icon(Icons.brightness_6_outlined),
            title: const Text('外观'),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              items: const [
                DropdownMenuItem(
                    value: ThemeMode.system, child: Text('跟随系统')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('亮色')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('暗色')),
              ],
              onChanged: (m) =>
                  m == null ? null : ref.read(themeControllerProvider.notifier).set(m),
            ),
          ),
          const Divider(),
          _SectionTitle('AI 配置 (BYOK)', theme),
          const _TextField(label: 'API Base URL', hint: 'https://api.openai.com/v1'),
          const _TextField(label: 'API Key', hint: 'sk-...', obscure: true),
          const _TextField(label: '文本模型', hint: 'gpt-4o'),
          const _TextField(label: '视觉模型', hint: 'gpt-4o'),
          const Divider(),
          _SectionTitle('翻译', theme),
          const _TextField(label: '目标语言', hint: '中文'),
          SwitchListTile(
            title: const Text('联网搜索'),
            value: false,
            onChanged: (_) {},
          ),
          const Divider(),
          _SectionTitle('OCR', theme),
          ListTile(
            leading: const Icon(Icons.document_scanner_outlined),
            title: const Text('识别模式'),
            subtitle: const Text('高精度（默认）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, this.theme);
  final String text;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.label,
    required this.hint,
    this.obscure = false,
  });

  final String label;
  final String hint;
  final bool obscure;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
