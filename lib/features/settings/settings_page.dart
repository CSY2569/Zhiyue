import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// Settings page (FEATURES §6.1, §8.2).
///
/// Theme + AI config (BYOK). The AI section keeps a local draft so edits are
/// not lost until the user saves; the save button is enabled once the API
/// key is non-empty (FLUTTER_UI_MIGRATION 4.3).
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _textModel = TextEditingController();
  final _visionBaseUrl = TextEditingController();
  final _visionApiKey = TextEditingController();
  final _visionModel = TextEditingController();
  final _targetLang = TextEditingController();
  final _searchBaseUrl = TextEditingController();
  final _searchApiKey = TextEditingController();
  bool _webSearch = false;
  bool _searchBuiltin = false;
  bool _loaded = false;
  bool _saving = false;

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _textModel.dispose();
    _visionBaseUrl.dispose();
    _visionApiKey.dispose();
    _visionModel.dispose();
    _targetLang.dispose();
    _searchBaseUrl.dispose();
    _searchApiKey.dispose();
    super.dispose();
  }

  /// Fill the draft from the persisted config once it arrives.
  void _hydrate(AiConfig? config) {
    if (_loaded || config == null) return;
    _loaded = true;
    _baseUrl.text = config.baseUrl;
    _apiKey.text = config.apiKey;
    _textModel.text = config.textModel;
    _visionBaseUrl.text = config.visionBaseUrl ?? '';
    _visionApiKey.text = config.visionApiKey ?? '';
    _visionModel.text = config.visionModel;
    _targetLang.text = config.translateTargetLang;
    _searchBaseUrl.text = config.searchBaseUrl ?? '';
    _searchApiKey.text = config.searchApiKey ?? '';
    _searchBuiltin = config.searchUseBuiltin;
    _webSearch = config.webSearchEnabled;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = AiConfig(
      baseUrl: _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim(),
      textModel: _textModel.text.trim(),
      visionModel: _visionModel.text.trim(),
      visionBaseUrl: _visionBaseUrl.text.trim().isEmpty
          ? null
          : _visionBaseUrl.text.trim(),
      visionApiKey: _visionApiKey.text.trim().isEmpty
          ? null
          : _visionApiKey.text.trim(),
      translateTargetLang:
          _targetLang.text.trim().isEmpty ? '中文' : _targetLang.text.trim(),
      searchBaseUrl: _searchBaseUrl.text.trim().isEmpty
          ? null
          : _searchBaseUrl.text.trim(),
      searchApiKey: _searchApiKey.text.trim().isEmpty
          ? null
          : _searchApiKey.text.trim(),
      searchUseBuiltin: _searchBuiltin,
      webSearchEnabled: _webSearch,
    );
    final ok = await ref.read(aiConfigProvider.notifier).save(config);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'AI 配置已保存' : '保存失败，请重试')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final themeMode = ref.watch(themeControllerProvider);
    final config = ref.watch(aiConfigProvider).valueOrNull;
    _hydrate(config);
    final canSave = !_saving && _apiKey.text.trim().isNotEmpty;

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
              onChanged: (m) => m == null
                  ? null
                  : ref.read(themeControllerProvider.notifier).set(m),
            ),
          ),
          const Divider(),
          _SectionTitle('文本与翻译配置（BYOK，兼容 OpenAI / DeepSeek / Kimi / 通义）', theme),
          _Field(controller: _baseUrl, label: 'API Base URL', hint: 'https://api.openai.com/v1'),
          _Field(
            controller: _apiKey,
            label: 'API Key',
            hint: 'sk-...',
            obscure: true,
            onChanged: (_) => setState(() {}), // re-evaluate save button
          ),
          _Field(controller: _textModel, label: '文本模型', hint: 'gpt-4o-mini'),
          _Field(controller: _targetLang, label: '翻译目标语言', hint: '中文'),
          _SectionTitle('视觉配置（可选，不填回退通用配置）', theme),
          _Field(controller: _visionBaseUrl, label: '视觉 Base URL', hint: '留空 = 使用通用配置'),
          _Field(
            controller: _visionApiKey,
            label: '视觉 API Key',
            hint: '留空 = 使用通用 Key',
            obscure: true,
          ),
          _Field(controller: _visionModel, label: '视觉模型', hint: 'gpt-4o / qwen-vl-max 等'),
          const Divider(),
          _SectionTitle('搜索配置', theme),
          SwitchListTile(
            title: const Text('联网搜索'),
            subtitle: const Text('开启后搜索动作先联网检索，再让模型基于真实结果作答'),
            value: _webSearch,
            onChanged: (v) => setState(() => _webSearch = v),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('搜索方式'),
            subtitle: Text(_searchBuiltin
                ? '模型内置搜索：由服务端联网（Responses API，需模型支持，如 DeepSeek）'
                : '第三方搜索：使用下方 Base URL + Key'),
            trailing: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('内置搜索'),
                  icon: Icon(Icons.language, size: 16),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('第三方搜索'),
                  icon: Icon(Icons.extension_outlined, size: 16),
                ),
              ],
              selected: {_searchBuiltin},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  setState(() => _searchBuiltin = s.first),
            ),
          ),
          _Field(
            controller: _searchBaseUrl,
            label: '搜索 API Base URL',
            hint: '留空 = 博查默认（https://api.bochaai.com/v1/web-search）',
          ),
          _Field(
            controller: _searchApiKey,
            label: '搜索 API Key',
            hint: '留空 = 降级为基于已有知识回答',
            obscure: true,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: canSave ? _save : null,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? '保存中…' : '保存 AI 配置'),
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

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.obscure = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final bool obscure;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
