import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/bilingual/providers/translation_config_provider.dart';
import 'package:rbwa/features/bilingual/widgets/engine_settings_card.dart';
import 'package:rbwa/features/settings/widgets/settings_widgets.dart';
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// 「对照阅读」 settings section (plan §8): translation service, source
/// language, translation mode, whole-book background behaviour, auto OCR,
/// concurrency, cache limit and the glossary editor.
///
/// The TARGET LANGUAGE is deliberately NOT configured here (plan §8 v4.2):
/// it is shared with 「AI 设置 → 翻译」 (AiConfig.translateTargetLang), shown
/// as a hint below. Edits are kept in a local draft and persisted with the
/// section's own save button (mirrors the AI section's draft pattern).
class TranslationSettingsSection extends ConsumerStatefulWidget {
  const TranslationSettingsSection({super.key});

  @override
  ConsumerState<TranslationSettingsSection> createState() =>
      _TranslationSettingsSectionState();
}

class _TranslationSettingsSectionState
    extends ConsumerState<TranslationSettingsSection> {
  final _baseUrl = TextEditingController();
  final _apiKey = TextEditingController();
  final _model = TextEditingController();
  final _glossarySource = TextEditingController();
  final _glossaryTarget = TextEditingController();

  TranslationProviderKind _provider = TranslationProviderKind.reuseAi;
  String _sourceLang = 'auto';
  TranslationMode _mode = TranslationMode.withProgress;
  TranslationBackgroundBehavior _background = TranslationBackgroundBehavior.ask;
  bool _autoOcr = true;
  int _concurrency = 2;
  int _cacheLimitMb = 2048;

  List<GlossaryEntry> _glossary = [];
  bool _loaded = false;
  bool _saving = false;
  bool _glossaryRequested = false;

  @override
  void initState() {
    super.initState();
    // Load the glossary once after the first frame (no provider reads during
    // initState / build side effects). Failures are non-fatal (widget tests
    // without an initialized Rust core).
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadGlossary());
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _apiKey.dispose();
    _model.dispose();
    _glossarySource.dispose();
    _glossaryTarget.dispose();
    super.dispose();
  }

  void _hydrate(TranslationConfig? config) {
    if (_loaded || config == null) return;
    _loaded = true;
    _provider = config.provider;
    _baseUrl.text = config.baseUrl ?? '';
    _apiKey.text = config.apiKey ?? '';
    _model.text = config.model ?? '';
    _sourceLang = config.sourceLang;
    _mode = config.mode;
    _background = config.backgroundBehavior;
    _autoOcr = config.autoOcr;
    _concurrency = config.concurrency;
    _cacheLimitMb = config.cacheLimitMb;
  }

  Future<void> _loadGlossary({bool force = false}) async {
    if (_glossaryRequested && !force) return;
    _glossaryRequested = true;
    try {
      final res = await ref.read(translationRepositoryProvider).listGlossary();
      if (!mounted) return;
      setState(() => _glossary = res.entries);
    } catch (_) {
      // Core not ready (widget tests): leave the list empty.
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final config = TranslationConfig(
      provider: _provider,
      baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
      apiKey: _apiKey.text.trim().isEmpty ? null : _apiKey.text.trim(),
      model: _model.text.trim().isEmpty ? null : _model.text.trim(),
      sourceLang: _sourceLang,
      mode: _mode,
      backgroundBehavior: _background,
      autoOcr: _autoOcr,
      concurrency: _concurrency,
      cacheLimitMb: _cacheLimitMb,
    );
    await ref.read(translationConfigProvider.notifier).save(config);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('已保存对照阅读设置')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final config = ref.watch(translationConfigProvider).valueOrNull;
    _hydrate(config);
    final targetLang = ref.watch(translateTargetLangProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // --- 翻译引擎（BabelDOC，按需下载） --------------------------------
        const EngineSettingsCard(),
        // --- 翻译服务 ---------------------------------------------------
        SettingsSection(
          title: '翻译服务',
          icon: Icons.cloud_outlined,
          description: '提供译文服务；引擎就绪后用于对照阅读与译文导出',
          children: [
            SettingsControlRow(
              title: '服务提供方',
              topPadding: 2,
              child: SegmentedButton<TranslationProviderKind>(
                segments: const [
                  ButtonSegment(
                      value: TranslationProviderKind.reuseAi,
                      label: Text('复用 AI')),
                  ButtonSegment(
                      value: TranslationProviderKind.deepL, label: Text('DeepL')),
                  ButtonSegment(
                      value: TranslationProviderKind.openAiCompat,
                      label: Text('自定义')),
                ],
                selected: {_provider},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _provider = s.first),
              ),
            ),
            if (_provider != TranslationProviderKind.reuseAi) ...[
              SettingsTextField(
                controller: _baseUrl,
                label: '服务地址',
                hint: 'https://api-free.deepl.com 或 OpenAI 兼容地址',
              ),
              SettingsTextField(
                controller: _apiKey,
                label: 'API Key',
                hint: '仅保存在本机',
                obscure: true,
              ),
            ],
            if (_provider == TranslationProviderKind.openAiCompat)
              SettingsTextField(
                controller: _model,
                label: '模型',
                hint: '如 gpt-4o-mini',
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.translate,
                      size: 16, color: theme.colorScheme.outline),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '目标语言沿用「AI 设置 → 翻译」：$targetLang',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SettingsControlRow(
              title: '源语言',
              child: DropdownButton<String>(
                value: _sourceLang,
                items: const [
                  DropdownMenuItem(value: 'auto', child: Text('自动判定')),
                  DropdownMenuItem(value: '中文', child: Text('中文')),
                  DropdownMenuItem(value: '英文', child: Text('英文')),
                  DropdownMenuItem(value: '日文', child: Text('日文')),
                  DropdownMenuItem(value: '法文', child: Text('法文')),
                  DropdownMenuItem(value: '德文', child: Text('德文')),
                ],
                onChanged: (v) =>
                    v == null ? null : setState(() => _sourceLang = v),
              ),
            ),
          ],
        ),

        // --- 翻译方式 ---------------------------------------------------
        SettingsSection(
          title: '翻译方式',
          icon: Icons.schedule_outlined,
          children: [
            SettingsControlRow(
              title: '何时翻译',
              description: switch (_mode) {
                TranslationMode.wholeBook => '整本书自动：确认后全书入队',
                TranslationMode.withProgress => '随进度：翻译本页与后两页（默认）',
                TranslationMode.manual => '手动：仅点击「翻译本页」时翻译',
              },
              topPadding: 2,
              child: SegmentedButton<TranslationMode>(
                segments: const [
                  ButtonSegment(
                      value: TranslationMode.wholeBook, label: Text('整本')),
                  ButtonSegment(
                      value: TranslationMode.withProgress,
                      label: Text('随进度')),
                  ButtonSegment(
                      value: TranslationMode.manual, label: Text('手动')),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
            ),
            SettingsControlRow(
              title: '整本翻译后台行为',
              description: switch (_background) {
                TranslationBackgroundBehavior.ask => '首次触发整本翻译时询问',
                TranslationBackgroundBehavior.continue_ =>
                  '后台继续：切书/关面板不取消',
                TranslationBackgroundBehavior.pauseResume => '切书暂停，回来续传',
                TranslationBackgroundBehavior.cancel => '离开即取消',
              },
              child: SegmentedButton<TranslationBackgroundBehavior>(
                segments: const [
                  ButtonSegment(
                      value: TranslationBackgroundBehavior.continue_,
                      label: Text('后台继续')),
                  ButtonSegment(
                      value: TranslationBackgroundBehavior.pauseResume,
                      label: Text('暂停续传')),
                  ButtonSegment(
                      value: TranslationBackgroundBehavior.cancel,
                      label: Text('离开取消')),
                ],
                selected: {_background == TranslationBackgroundBehavior.ask
                    ? TranslationBackgroundBehavior.continue_
                    : _background},
                showSelectedIcon: false,
                onSelectionChanged: (s) =>
                    setState(() => _background = s.first),
              ),
            ),
            SettingsSwitchRow(
              title: '扫描版自动 OCR',
              description: '扫描页无文字层时先本地识别再翻译（低置信会标注）',
              value: _autoOcr,
              onChanged: (v) => setState(() => _autoOcr = v),
            ),
          ],
        ),

        // --- 性能与存储 -------------------------------------------------
        SettingsSection(
          title: '性能与存储',
          icon: Icons.speed_outlined,
          children: [
            SettingsControlRow(
              title: '整本翻译并发数',
              description: '并发 $_concurrency 页（过高可能触发限流）',
              topPadding: 2,
              child: Slider(
                value: _concurrency.toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                label: '$_concurrency',
                onChanged: (v) => setState(() => _concurrency = v.round()),
              ),
            ),
            SettingsControlRow(
              title: '缓存上限',
              description: '${_cacheLimitMb ~/ 1024} GB（超出后按最久未访问清理产物）',
              child: Slider(
                value: _cacheLimitMb.toDouble(),
                min: 256,
                max: 8192,
                divisions: 31,
                label: '${_cacheLimitMb ~/ 1024} GB',
                onChanged: (v) =>
                    setState(() => _cacheLimitMb = (v / 256).round() * 256),
              ),
            ),
          ],
        ),

        // --- 术语表 -----------------------------------------------------
        SettingsSection(
          title: '术语表',
          icon: Icons.menu_book_outlined,
          description: '固定译名，全书保持一致',
          children: [
            Row(
              children: [
                Expanded(
                  child: SettingsTextField(
                    controller: _glossarySource,
                    label: '原文术语',
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SettingsTextField(
                    controller: _glossaryTarget,
                    label: '译文术语',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, top: 6),
                  child: IconButton.filledTonal(
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: '添加术语',
                    onPressed: () async {
                      final s = _glossarySource.text.trim();
                      final t = _glossaryTarget.text.trim();
                      if (s.isEmpty || t.isEmpty) return;
                      await ref
                          .read(translationRepositoryProvider)
                          .addGlossaryEntry(sourceTerm: s, targetTerm: t);
                      _glossarySource.clear();
                      _glossaryTarget.clear();
                      await _loadGlossary(force: true);
                    },
                  ),
                ),
              ],
            ),
            if (_glossary.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  '暂无术语',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              )
            else
              for (final e in _glossary)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${e.sourceTerm} → ${e.targetTerm}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18),
                    tooltip: '删除',
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await ref
                          .read(translationRepositoryProvider)
                          .deleteGlossaryEntry(e.id.toInt());
                      await _loadGlossary(force: true);
                    },
                  ),
                ),
          ],
        ),

        // --- 固定保留 ---------------------------------------------------
        SettingsSection(
          title: '固定保留',
          icon: Icons.push_pin_outlined,
          description: '勾选的书不会被缓存清理',
          children: const [_PinnedBooksEditor()],
        ),

        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? '保存中…' : '保存对照阅读设置'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
          ),
        ),
      ],
    );
  }
}

/// Pinned-books editor (plan §7): pins keep a book's translation artifacts
/// out of the LRU sweep. Titles come from the library; ids persist in the
/// settings KV `translation_pinned_books` (a JSON array).
class _PinnedBooksEditor extends ConsumerStatefulWidget {
  const _PinnedBooksEditor();

  @override
  ConsumerState<_PinnedBooksEditor> createState() => _PinnedBooksEditorState();
}

class _PinnedBooksEditorState extends ConsumerState<_PinnedBooksEditor> {
  List<Book> _books = [];
  Set<int> _pinned = {};
  bool _loadedPins = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final bookList = await ref.read(libraryRepositoryProvider).listBooks();
        final raw = await ref
            .read(settingsRepositoryProvider)
            .getSetting('translation_pinned_books');
        if (!mounted) return;
        setState(() {
          _books = bookList;
          _pinned = _parsePinned(raw);
          _loadedPins = true;
        });
      } catch (_) {
        // Core not ready (widget tests) -- keep the section non-fatal.
        if (mounted) setState(() => _loadedPins = true);
      }
    });
  }

  Set<int> _parsePinned(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list.map((e) => (e as num).toInt()).toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _toggle(int bookId, bool on) async {
    setState(() => on ? _pinned.add(bookId) : _pinned.remove(bookId));
    await ref.read(settingsRepositoryProvider).setSetting(
          'translation_pinned_books',
          jsonEncode(_pinned.toList()..sort()),
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!_loadedPins) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (_books.isEmpty) {
      return Text(
        '书库暂无书籍。',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.outline),
      );
    }
    return Column(
      children: [
        for (final b in _books)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            value: _pinned.contains(b.id.toInt()),
            onChanged: (v) => _toggle(b.id.toInt(), v ?? false),
          ),
      ],
    );
  }
}
