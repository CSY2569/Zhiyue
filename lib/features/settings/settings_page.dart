import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
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
  String _ocrMode = 'high_precision';
  bool _includeBookHistory = true;
  bool _enableReasoning = false;
  String _reasoningEffort = 'medium';
  double _temperature = 0.7;
  String _promptTemplate = 'general';
  final _customPrompt = TextEditingController();
  final _customPromptName = TextEditingController();
  final _templateEdit = TextEditingController();
  List<CustomPrompt> _savedTemplates = [];
  /// User edits of the built-in templates (template id -> text); persisted
  /// as template_overrides. The async-loaded defaults live in the other map.
  final Map<String, String> _templateEdits = {};
  final Map<String, String> _templateDefaults = {};
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
    _customPrompt.dispose();
    _customPromptName.dispose();
    _templateEdit.dispose();
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
    _ocrMode = config.ocrMode == 'fast' ? 'fast' : 'high_precision';
    _includeBookHistory = config.includeBookHistory;
    _enableReasoning = config.enableReasoning;
    _reasoningEffort = const {'low', 'medium', 'high'}.contains(config.reasoningEffort)
        ? config.reasoningEffort
        : 'medium';
    _temperature = config.temperature.clamp(0.0, 2.0);
    _promptTemplate = config.promptTemplate;
    _customPrompt.text = config.customPrompt;
    _savedTemplates = [...config.customPrompts];
    _templateEdits
      ..clear()
      ..addAll(config.templateOverrides);
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
      ocrMode: _ocrMode,
      includeBookHistory: _includeBookHistory,
      enableReasoning: _enableReasoning,
      reasoningEffort: _reasoningEffort,
      temperature: _temperature,
      promptTemplate: _promptTemplate,
      customPrompt: _customPrompt.text.trim(),
      customPrompts: _savedTemplates,
      templateOverrides: _templateEdits,
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
          const Divider(),
          _SectionTitle('AI 回复', theme),
          SwitchListTile(
            title: const Text('携带书籍对话上下文'),
            subtitle: const Text('每次回复携带本书与 AI 的全部对话历史（追问从开始到本次）。关闭后每轮独立回答'),
            value: _includeBookHistory,
            onChanged: (v) => setState(() => _includeBookHistory = v),
          ),
          SwitchListTile(
            title: const Text('思考模式'),
            subtitle: const Text('开启后按官方 API 发送 reasoning_effort，需使用支持思考的模型（如 o 系列 / GPT-5 / DeepSeek-R1）'),
            value: _enableReasoning,
            onChanged: (v) => setState(() => _enableReasoning = v),
          ),
          if (_enableReasoning)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('思考等级'),
              trailing: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'low', label: Text('低')),
                  ButtonSegment(value: 'medium', label: Text('中')),
                  ButtonSegment(value: 'high', label: Text('高')),
                ],
                selected: {_reasoningEffort},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _reasoningEffort = s.first),
              ),
            ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('温度'),
            subtitle: Text('随机性（0.0 确定 – 2.0 发散）：${_temperature.toStringAsFixed(1)}'),
            trailing: SizedBox(
              width: 200,
              child: Slider(
                value: _temperature,
                min: 0,
                max: 2,
                divisions: 20,
                label: _temperature.toStringAsFixed(1),
                onChanged: (v) => setState(() => _temperature = v),
              ),
            ),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('提示词模板'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final t in _templateOptions)
                    ChoiceChip(
                      label: Text(t.label),
                      selected: _promptTemplate == t.id,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => _selectTemplate(t.id),
                    ),
                ],
              ),
            ),
          ),
          if (_promptTemplate != 'custom') ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _templateEdit,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '模板提示词（可修改，保存后生效）',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) => _templateEdits[_promptTemplate] = v,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _restoreTemplate,
                icon: const Icon(Icons.restore, size: 16),
                label: const Text('恢复默认'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ],
          if (_promptTemplate == 'custom') ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _customPromptName,
                decoration: const InputDecoration(
                  labelText: '模板名称（保存后用于选择）',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customPrompt,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '自定义提示词（作为角色设定，动作指令自动保留）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _saveTemplate,
                icon: const Icon(Icons.bookmark_add_outlined, size: 16),
                label: const Text('保存为模板'),
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            if (_savedTemplates.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                '已保存模板（点击选用，可删除）',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.primary),
              ),
              for (final t in _savedTemplates)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined, size: 18),
                  title: Text(t.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(t.text,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除模板',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() =>
                        _savedTemplates.removeWhere((x) => x.name == t.name)),
                  ),
                  onTap: () {
                    _customPrompt.text = t.text;
                    setState(() {});
                  },
                ),
            ],
          ],
          const Divider(),
          _SectionTitle('OCR 整页扫描（本地离线，FEATURES 7.1.9）', theme),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('识别模式'),
            subtitle: Text(
              _ocrMode == 'fast'
                  ? '快速：mobile 模型，速度与体积优先（约 16MB）'
                  : '高精度：server 模型，准确率优先（约 200MB，需先运行 '
                      'scripts/download_ocr_models.sh 下载）',
            ),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'high_precision',
                  label: Text('高精度'),
                  icon: Icon(Icons.high_quality_outlined, size: 16),
                ),
                ButtonSegment(
                  value: 'fast',
                  label: Text('快速'),
                  icon: Icon(Icons.bolt_outlined, size: 16),
                ),
              ],
              selected: {_ocrMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _ocrMode = s.first),
            ),
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

  /// Pick a template chip: the built-in ones show their (editable) text;
  /// the default text loads from Rust on first selection.
  void _selectTemplate(String id) {
    setState(() {
      _promptTemplate = id;
      _templateEdit.text =
          _templateEdits[id] ?? _templateDefaults[id] ?? '';
    });
    if (id == 'custom') return;
    if (_templateEdits.containsKey(id) || _templateDefaults.containsKey(id)) {
      return;
    }
    ref.read(aiRepositoryProvider).templateDefaultText(id).then((t) {
      if (!mounted || _promptTemplate != id) return;
      setState(() {
        _templateDefaults[id] = t;
        _templateEdit.text = t;
      });
    });
  }

  /// Drop the user edit of the current template (back to the built-in).
  void _restoreTemplate() {
    final id = _promptTemplate;
    setState(() {
      _templateEdits.remove(id);
      _templateEdit.text = _templateDefaults[id] ?? '';
    });
  }

  /// Save the current custom prompt as a named template (同名覆盖).
  void _saveTemplate() {
    final name = _customPromptName.text.trim();
    final text = _customPrompt.text.trim();
    if (name.isEmpty || text.isEmpty) return;
    setState(() {
      _savedTemplates.removeWhere((t) => t.name == name);
      _savedTemplates.add(CustomPrompt(name: name, text: text));
    });
  }
}

/// The selectable prompt templates (id -> label), shown as a chip row.
const _templateOptions = [
  (id: 'general', label: '通用'),
  (id: 'academic', label: '学术论文'),
  (id: 'novel', label: '小说文学'),
  (id: 'tech', label: '技术文档'),
  (id: 'language', label: '外语学习'),
  (id: 'historical', label: '历史文献'),
  (id: 'legal', label: '法律文书'),
  (id: 'classical', label: '文言文'),
  (id: 'ai', label: 'AI 技术'),
  (id: 'custom', label: '自定义'),
];

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
