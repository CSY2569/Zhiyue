import 'dart:convert' show base64Decode;

import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/pages/ai_conversations_page.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/ai_panel_side.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';
import 'package:rbwa/features/annotation/models/selection.dart';
import 'package:rbwa/features/annotation/providers/selection_provider.dart';
import 'package:rbwa/features/annotation/widgets/floating_toolbar.dart';
import 'package:rbwa/features/settings/settings_page.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/models/ai.dart';

import 'helpers/fake_ai_repo.dart';

/// 1x1 transparent PNG used as a fake vision capture.
final kTinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');


ProviderScope _scope(Widget child, FakeAiRepo repo) => ProviderScope(
      // Stack so Positioned-based floating widgets (toolbar / selector)
      // render correctly.
      overrides: [aiRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: Scaffold(body: Stack(children: [child]))),
    );


void main() {
  testWidgets('settings page loads and saves AI config (6.1)', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // Draft hydrated from the persisted config. The fields sit below the
    // 主题 / 阅读器设置 sections, so scroll them into view first.
    await tester.scrollUntilVisible(
      find.widgetWithText(TextField, 'http://mock/v1'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.widgetWithText(TextField, 'http://mock/v1'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'mock-key'), findsOneWidget);

    // The save button sits below the fold of the settings ListView.
    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();

    // Save button is enabled once the API key is non-empty.
    final saveBtn = find.widgetWithText(FilledButton, '保存 AI 配置');
    expect(tester.widget<FilledButton>(saveBtn).onPressed, isNotNull);

    await tester.tap(saveBtn);
    await tester.pumpAndSettle();

    expect(repo.saved, isNotNull);
    expect(repo.saved!.apiKey, 'mock-key');
    expect(repo.saved!.webSearchEnabled, isTrue);
    // AI reply defaults persist with the config.
    expect(repo.saved!.includeBookHistory, isTrue);
    expect(repo.saved!.enableReasoning, isFalse);
    expect(repo.saved!.reasoningEffort, 'medium');
    expect(repo.saved!.temperature, 0.7);
    expect(repo.saved!.promptTemplate, 'general');
    // Protocol defaults to Chat Completions when untouched.
    expect(repo.saved!.apiProtocol, 'chat_completions');
    expect(find.text('AI 配置已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings page switches the API protocol to Responses',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // The API 协议 control sits next to the text model.
    final responses = find.widgetWithText(SegmentedButton<String>, 'Responses');
    await tester.ensureVisible(responses);
    await tester.pump();
    await tester.tap(find.text('Responses'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.apiProtocol, 'responses');
    expect(tester.takeException(), isNull);
  });


  testWidgets('built-in template text is editable and persists',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // Select a built-in template: its text shows (loaded from Rust).
    await tester.scrollUntilVisible(
      find.text('提示词模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, '学术论文'));
    await tester.pumpAndSettle();
    expect(find.text('默认学术文本'), findsOneWidget);

    // Edit the text and save: the override persists with the config.
    await tester.scrollUntilVisible(
      find.widgetWithText(TextField, '模板提示词（可修改，保存后生效）'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.enterText(
        find.widgetWithText(TextField, '模板提示词（可修改，保存后生效）'),
        '我修改过的学术提示词');
    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.templateOverrides['academic'], '我修改过的学术提示词');
    expect(repo.saved!.promptTemplate, 'academic');
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI reply settings: thinking level and custom prompt persist',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // Enable thinking mode: the level selector appears.
    await tester.scrollUntilVisible(
      find.text('思考模式'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('思考模式'));
    await tester.pumpAndSettle();
    expect(find.text('思考等级'), findsOneWidget);
    await tester.tap(find.text('高'));
    await tester.pump();

    // Switch to the custom template chip: the prompt editor appears.
    await tester.scrollUntilVisible(
      find.text('提示词模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, '自定义提示词（作为角色设定，动作指令自动保留）'),
        '你是一位诗人');
    await tester.pump();

    // Save and verify the new fields round-trip.
    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.enableReasoning, isTrue);
    expect(repo.saved!.reasoningEffort, 'high');
    expect(repo.saved!.promptTemplate, 'custom');
    expect(repo.saved!.customPrompt, '你是一位诗人');
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom prompts can be named, saved and reused', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // Switch to the custom template chip.
    await tester.scrollUntilVisible(
      find.text('提示词模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.text('+'));
    await tester.pumpAndSettle();

    // Name + text + save as a template.
    await tester.enterText(
        find.widgetWithText(TextField, '模板名称（保存后用于选择）'), '诗人');
    await tester.enterText(
        find.widgetWithText(TextField, '自定义提示词（作为角色设定，动作指令自动保留）'),
        '你是一位诗人');
    await tester.tap(find.text('保存为模板'));
    await tester.pumpAndSettle();
    // The saved list shows the named template (its delete button), and
    // the template picker gains a chip for it. The saved row sits below the
    // fold on a shorter list, so scroll it into view first.
    await tester.scrollUntilVisible(
      find.byTooltip('删除模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.byTooltip('删除模板'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '诗人'), findsOneWidget);

    // Tapping the saved chip activates it (custom section fills).
    await tester.tap(find.widgetWithText(ChoiceChip, '诗人'));
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(TextField, '自定义提示词（作为角色设定，动作指令自动保留）'),
      findsOneWidget,
    );

    // Persist: the named template travels with the config.
    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.customPrompts, hasLength(1));
    expect(repo.saved!.customPrompts.single.name, '诗人');
    expect(repo.saved!.customPrompts.single.text, '你是一位诗人');
    expect(repo.saved!.customPrompt, '你是一位诗人');

    // Deleting the template removes its chip from the picker at once.
    await tester.scrollUntilVisible(
      find.byTooltip('删除模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('删除模板'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除模板'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, '诗人'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: translation language chips + custom language',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // Built-in target languages are chips; pick 英文.
    await tester.scrollUntilVisible(
      find.text('目标语言'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.widgetWithText(ChoiceChip, '中文'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '英文'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '中英互译'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '英文'));
    await tester.pumpAndSettle();

    // Add a custom language: it appears as a chip and becomes the selection.
    await tester.tap(find.widgetWithText(ActionChip, '添加语言'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '语言名称'), '日文');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, '日文'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.translateTargetLang, '日文');
    expect(repo.saved!.translateCustomLangs, contains('日文'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: search config hides when built-in search is chosen',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    // FakeAiRepo defaults to third-party search -> the API fields show.
    await tester.scrollUntilVisible(
      find.text('搜索方式'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(find.text('搜索 API Key'), findsOneWidget);

    // Built-in search reuses the general Responses config: fields hide.
    await tester.tap(find.text('内置搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索 API Key'), findsNothing);

    // Back to third-party -> fields return.
    await tester.tap(find.text('第三方搜索'));
    await tester.pumpAndSettle();
    expect(find.text('搜索 API Key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: vision config shows only when the model is text-only',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('模型能力'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    // Default: text-only -> the vision override is shown.
    expect(find.text('视觉模型'), findsOneWidget);

    // Ticking 图片 marks the general model multimodal -> hide the override.
    await tester.tap(find.widgetWithText(FilterChip, '图片'));
    await tester.pumpAndSettle();
    expect(find.text('视觉模型'), findsNothing);

    // Untick -> it comes back.
    await tester.tap(find.widgetWithText(FilterChip, '图片'));
    await tester.pumpAndSettle();
    expect(find.text('视觉模型'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: embedding search toggle reveals and persists config',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('启用嵌入搜索'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    // Off by default -> the config fields are hidden.
    expect(find.text('Embedding API Key'), findsNothing);

    await tester.tap(find.text('启用嵌入搜索'));
    await tester.pumpAndSettle();
    expect(find.text('Embedding API Key'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Embedding 模型 ID'), 'text-embedding-3-small');
    await tester.enterText(
        find.widgetWithText(TextField, '向量数据库 URL'), 'http://localhost:6333');
    await tester.enterText(
        find.widgetWithText(TextField, '集合名称'), 'zhiyue');

    await tester.scrollUntilVisible(
      find.text('保存 AI 配置'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '保存 AI 配置'));
    await tester.pumpAndSettle();

    expect(repo.saved!.embeddingEnabled, isTrue);
    expect(repo.saved!.embeddingModel, 'text-embedding-3-small');
    expect(repo.saved!.vectorDbUrl, 'http://localhost:6333');
    expect(repo.saved!.vectorDbCollection, 'zhiyue');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: the selected template prompt shows on first entry',
      (tester) async {
    // Regression: the template edit box was empty on first entry -- the
    // selected template's prompt only appeared after re-clicking its chip.
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('提示词模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    // The default config selects "general"; its prompt must be pre-filled.
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, '模板提示词（可修改，保存后生效）'),
    );
    expect(field.controller!.text, '默认通用文本');
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings: an overridden template shows the user text on entry',
      (tester) async {
    final repo = FakeAiRepo();
    repo.configOverride = AiConfig(
      baseUrl: 'http://mock/v1',
      apiKey: 'mock-key',
      textModel: 'mock-text',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      translateCustomLangs: const [],
      modelSupportsVision: false,
      webSearchEnabled: false,
      searchUseBuiltin: false,
      ocrMode: 'high_precision',
      includeBookHistory: true,
      enableReasoning: false,
      reasoningEffort: 'medium',
      temperature: 0.7,
      apiProtocol: 'chat_completions',
      promptTemplate: 'academic',
      customPrompt: '不该出现的自定义提示',
      customPrompts: const [],
      templateOverrides: const {'academic': '我改过的学术提示'},
      embeddingEnabled: false,
      embeddingBaseUrl: null,
      embeddingApiKey: null,
      embeddingModel: '',
      vectorDbUrl: null,
      vectorDbApiKey: null,
      vectorDbCollection: '',
    );

    await tester.pumpWidget(_scope(const SettingsPage(), repo));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('提示词模板'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, '模板提示词（可修改，保存后生效）'),
    );
    // The user's override wins; the custom prompt must NOT leak in here.
    expect(field.controller!.text, '我改过的学术提示');
    expect(field.controller!.text, isNot(contains('不该出现')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating toolbar translate button starts an AI action',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const FloatingToolbar(), repo));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(FloatingToolbar)),
    );
    // Commit a selection so the toolbar is visible.
    final sel = Selection(
      page: 0,
      anchorIndex: 0,
      currentIndex: 2,
      text: 'hello world',
      lineRects: const [NormRect(x: 0.1, y: 0.1, w: 0.5, h: 0.03)],
    );
    container
        .read(selectionProvider.notifier)
        .commitSelection(sel, const Rect.fromLTWH(100, 100, 200, 20));
    await tester.pump();

    await tester.tap(find.text('翻译'));
    await tester.pumpAndSettle();

    expect(repo.sent, [(AiActionType.translate, 'hello world')]);
    // Selection cleared with the toolbar (the card takes over).
    expect(container.read(selectionProvider).selection, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('result card stays visible after streaming finishes (6.4.1)',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    // Streaming finished: the card must NOT close -- it shows the full answer
    // with copy / expand / close actions (regression: it used to vanish).
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(container.read(aiProvider).cardStreaming, isFalse);
    expect(find.textContaining('答案'), findsOneWidget);
    expect(find.byTooltip('复制对话'), findsOneWidget);
    expect(find.byTooltip('展开到侧栏'), findsOneWidget);
    expect(find.byTooltip('停止生成'), findsNothing); // no longer streaming

    // Closing is an explicit user action: the close button only.
    await tester.tap(find.byTooltip('关闭'));
    await tester.pump();
    expect(container.read(aiProvider).cardVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('result card supports follow-up conversation (6.5.2)', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q', bookId: null, bookTitle: null);
    await tester.pumpAndSettle();
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(container.read(aiProvider).cardStreaming, isFalse);

    // Type a follow-up in the card input and send with Enter (FEATURES 8.9).
    await tester.enterText(find.byType(TextField), '再解释一下');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // Sent to the same thread (full history), streamed into the card.
    expect(repo.sent,
        [(AiActionType.explain, 'q'), (AiActionType.explain, '再解释一下')]);
    // The card never auto-closes: still visible after the follow-up.
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(container.read(aiProvider).cardStreaming, isFalse);
    // Full history is kept and visible on the card (previous turns stay).
    final thread = container
        .read(aiProvider)
        .threadOf(container.read(aiProvider).activeThreadId)!;
    expect(
      thread.messages.map((m) => m.content).toList(),
      ['q', '答案', '再解释一下', '答案'],
    );
    expect(find.text('q'), findsOneWidget);
    expect(find.text('再解释一下'), findsOneWidget);
    expect(find.textContaining('答案'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel follow-up keeps the card open (no auto-close)',
      (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));
    final notifier = container.read(aiProvider.notifier);

    await notifier.startAction(AiActionType.explain, 'q',
        bookId: null, bookTitle: null);
    await tester.pumpAndSettle();
    final threadId = container.read(aiProvider).activeThreadId!;

    // A follow-up sent from the side panel must not hide the card.
    await notifier.sendMessage(threadId, '从面板追问');
    await tester.pumpAndSettle();
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(container.read(aiProvider).cardStreaming, isFalse);
    final thread = container.read(aiProvider).threadOf(threadId)!;
    expect(
      thread.messages.map((m) => m.content).toList(),
      ['q', '答案', '从面板追问', '答案'],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('errors appear on the result card with the provider message',
      (tester) async {
    final repo = FakeAiRepo()..failStream = true;
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.translate, 'hi',
            bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    // The error text (HTTP 400 + provider message) is visible on the card.
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(find.textContaining('⚠️'), findsOneWidget);
    expect(find.textContaining('Model Not Exist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });











  testWidgets('新会话打开为空页，历史经「查看历史对话」进入 (6.5.4)', (tester) async {
    final repo = FakeAiRepo();
    // A thread persisted by a previous session: user + assistant turns, plus
    // a vision turn whose screenshot was persisted to disk.
    final res = await repo.createAiThread(
      title: '翻译：hello',
      actionType: AiActionType.translate,
      bookId: null,
    );
    await repo.appendAiMessage(threadId: res.id, role: AiRole.user, content: 'hello');
    await repo.appendAiMessage(
        threadId: res.id, role: AiRole.assistant, content: '你好');
    final png = kTinyPng;
    await repo.appendAiMessage(
      threadId: res.id,
      role: AiRole.user,
      content: '（区域截图）',
      imagePng: png,
    );
    await repo.appendAiMessage(
        threadId: res.id, role: AiRole.assistant, content: '识别结果');

    // A fresh app: the panel boots and loads history, but a new conversation
    // opens on the EMPTY guide -- no historical messages are shown.
    await tester.pumpWidget(ProviderScope(
      overrides: [aiRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 320, height: 600, child: AiPanelSide()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiPanelSide)),
    );
    final state = container.read(aiProvider);
    expect(state.threads.length, 1);
    expect(state.threads.first.dbId, res.id);
    // 需求1: history is loaded but never auto-selected.
    expect(state.activeThreadId, isNull);
    expect(find.textContaining('选择文字翻译'), findsOneWidget);
    expect(find.text('hello'), findsNothing);
    expect(find.text('你好'), findsNothing);
    expect(find.text('查看历史对话'), findsOneWidget);

    // The guide's button opens the window list; opening the window shows the
    // full history, including the restored vision screenshot.
    await tester.tap(find.text('查看历史对话'));
    await tester.pumpAndSettle();
    expect(find.text('对话窗口'), findsOneWidget);
    await tester.tap(find.text('翻译：hello'));
    await tester.pumpAndSettle();
    expect(find.text('hello'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('（区域截图）'), findsOneWidget);
    final restored = state.threads.first.messages[2];
    expect(restored.imagePath, isNotNull); // persisted screenshot restored
    expect(restored.imagePng, isNull); // bytes live only in the live session
    expect(find.byType(Image), findsOneWidget); // the screenshot thumbnail

    // A follow-up on the restored thread persists too.
    await tester.enterText(find.byType(TextField), '再说一次');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.savedMessages[res.id]!.map((m) => m.content).toList(),
        ['hello', '你好', '（区域截图）', '识别结果', '再说一次', '答案']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('识图: startVision streams into the card, keeps the image, '
      'and persists the thread', (tester) async {
    final repo = FakeAiRepo()..visionChunks = const ['答', '案'];
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    // A real 1x1 transparent PNG so the card can actually render it.
    final png = kTinyPng;
    await container.read(aiProvider.notifier).startVision(png,
        bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    // The PNG went to the vision stream; the answer streamed into the card.
    expect(repo.visionCalls, hasLength(1));
    expect(repo.visionCalls.single, png);
    expect(container.read(aiProvider).cardVisible, isTrue);
    expect(find.textContaining('答案'), findsOneWidget);

    // The vision thread: user turn carries the screenshot in memory, the
    // answer is the assistant turn; both persisted as text rows and the
    // screenshot was persisted to disk (its path comes back on reload).
    final thread = container
        .read(aiProvider)
        .threadOf(container.read(aiProvider).activeThreadId)!;
    expect(thread.action, AiActionType.vision);
    expect(thread.messages.first.content, '（区域截图）');
    expect(thread.messages.first.imagePng, png);
    expect(thread.messages.last.content, '答案');
    expect(repo.savedMessages.values.first.map((m) => m.content).toList(),
        ['（区域截图）', '答案']);
    expect(repo.savedImages.values.first.single, png);
    expect(repo.savedMessages.values.first.first.imagePath, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('点击截图缩略图弹出大图，再点关闭', (tester) async {
    final repo = FakeAiRepo()..visionChunks = const ['答'];
    await tester.pumpWidget(_scope(
      const SizedBox(width: 320, height: 600, child: AiPanelSide()),
      repo,
    ));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AiPanelSide)));

    final png = kTinyPng;
    await container
        .read(aiProvider.notifier)
        .startVision(png, bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    // The panel shows the vision turn with its screenshot thumbnail.
    expect(find.text('（区域截图）'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    // Clicking the thumbnail pops the screenshot up at full size.
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    // Clicking the dialog closes it again.
    await tester.tap(find.byType(InteractiveViewer));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('同一本书的多次操作合并为一个对话窗口 (6.5.4)', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.translate, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q2',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();

    // One window per book: both turns share it, titled with the book name.
    final state = container.read(aiProvider);
    expect(state.threads.length, 1);
    final window = state.threads.single;
    expect(window.bookId, 1);
    expect(window.title, '三体');
    expect(window.action, AiActionType.explain); // latest action icon
    expect(window.messages.map((m) => m.content).toList(),
        ['q1', '答案', 'q2', '答案']);

    // Persisted as one window bound to the book.
    expect(repo.savedThreads.length, 1);
    expect(repo.savedBookIds.values.single, 1);
    expect(repo.savedMessages.values.first.map((m) => m.content).toList(),
        ['q1', '答案', 'q2', '答案']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('不同书各自一个对话窗口，换书后自动跟随', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.translate, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();

    // Switch to another book: a new window is created for it.
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.explain, 'q2',
            bookId: 2, bookTitle: '球状闪电');
    await tester.pumpAndSettle();

    final state = container.read(aiProvider);
    expect(state.threads.length, 2);
    expect(state.threads.map((w) => w.bookId).toSet(), {1, 2});
    expect(state.threads.map((w) => w.title).toSet(), {'三体', '球状闪电'});
    // The latest action selected the second book's window.
    expect(state.activeThreadId, state.threads.last.id);
    expect(repo.savedBookIds.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无书提问进入「未打开书籍」窗口', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container.read(aiProvider.notifier).askQuestion('hello',
        bookId: null, bookTitle: null);
    await tester.pumpAndSettle();

    final window = container.read(aiProvider).threads.single;
    expect(window.bookId, isNull);
    expect(window.title, '未打开书籍');
    expect(window.action, AiActionType.chat);
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除对话窗口：内存、卡片与持久化同步移除', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const ResultCard(), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(ResultCard)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.translate, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    final windowId = container.read(aiProvider).activeThreadId!;

    await container.read(aiProvider.notifier).deleteWindow(windowId);
    await tester.pumpAndSettle();

    final state = container.read(aiProvider);
    expect(state.threads, isEmpty);
    expect(state.activeThreadId, isNull);
    expect(state.cardVisible, isFalse); // the card showed the deleted window
    expect(repo.deletedThreads, [windowId]);
    expect(repo.savedThreads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('对话页可返回窗口列表', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SizedBox(width: 320, height: 600, child: AiPanelSide()), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AiPanelSide)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.chat, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    // Inside the conversation: the chat view is shown.
    expect(find.text('q1'), findsOneWidget);
    expect(find.byTooltip('对话列表'), findsOneWidget);

    // Back to the window list.
    await tester.tap(find.byTooltip('对话列表'));
    await tester.pumpAndSettle();
    expect(find.text('对话窗口'), findsOneWidget);
    expect(find.text('三体'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('清空只清当前显示，不删消息 (6.5.3)', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SizedBox(width: 320, height: 600, child: AiPanelSide()), repo));
    final container =
        ProviderScope.containerOf(tester.element(find.byType(AiPanelSide)));

    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.chat, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    expect(find.text('q1'), findsOneWidget); // conversation displayed

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    // The current view is cleared to the empty guide -- the history window
    // list must NOT reappear (and neither does its entry button).
    expect(container.read(aiProvider).activeThreadId, isNull);
    expect(find.text('对话窗口'), findsNothing);
    expect(find.text('三体'), findsNothing);
    expect(find.textContaining('选择文字翻译'), findsOneWidget);
    expect(find.text('查看历史对话'), findsNothing);
    expect(find.text('q1'), findsNothing);
    // ...but windows and messages are untouched, in memory and in the repo.
    expect(container.read(aiProvider).threads, hasLength(1));
    expect(repo.savedThreads, hasLength(1));
    expect(repo.savedMessages.values.first.map((m) => m.content).toList(),
        ['q1', '答案']);

    // The next AI action brings the conversation back into view.
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.chat, 'q2',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    expect(find.text('q2'), findsOneWidget);
    expect(find.textContaining('选择文字翻译'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('「AI 对话」页按书展示对话并可删除', (tester) async {
    final repo = FakeAiRepo();
    await tester.pumpWidget(_scope(const SizedBox(width: 900, height: 600, child: AiConversationsPage()), repo));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(AiConversationsPage)),
    );

    // Two books with conversations.
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.translate, 'q1',
            bookId: 1, bookTitle: '三体');
    await tester.pumpAndSettle();
    await container
        .read(aiProvider.notifier)
        .startAction(AiActionType.chat, 'q2',
            bookId: 2, bookTitle: '球状闪电');
    await tester.pumpAndSettle();

    // Left pane lists both books.
    expect(find.text('三体'), findsOneWidget);
    expect(find.text('球状闪电'), findsOneWidget);

    // Clicking a book shows its full conversation on the right.
    await tester.tap(find.text('三体'));
    await tester.pumpAndSettle();
    expect(find.text('q1'), findsOneWidget);
    expect(find.text('答案'), findsWidgets);
    expect(find.text('q2'), findsNothing);

    // Deletion is centralized here: confirm removes the book's window.
    await tester.tap(find.byTooltip('删除对话').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('确定删除「三体」的对话'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    final state = container.read(aiProvider);
    expect(state.threads.length, 1);
    expect(state.threads.single.title, '球状闪电');
    expect(find.text('三体'), findsNothing);
    expect(repo.deletedThreads, hasLength(1));
    expect(repo.savedThreads.length, 1);
    expect(tester.takeException(), isNull);
  });
}
