import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

import 'helpers/smoke_helpers.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// Local OpenAI-compatible mock: serves SSE chat completions (or Responses
/// API events in `responsesMode`) and records request bodies + paths so the
/// integration test can assert what Rust actually sent.
class MockOpenAi {
  MockOpenAi({
    required this.chunks,
    this.errorStatus,
    this.errorBody,
    this.errorPath,
  });

  final List<String> chunks;

  /// When set, requests to [errorPath] (default: all) answer with this HTTP
  /// status + body (used to verify provider error messages reach the UI and
  /// that a failed search can fall back while chat completions still work).
  final int? errorStatus;
  final String? errorBody;
  final String? errorPath;
  final requests = <Map<String, dynamic>>[];
  final requestPaths = <String>[];
  late HttpServer server;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      requestPaths.add(req.uri.path);
      if (req.method != 'POST') {
        req.response.statusCode = 405;
        await req.response.close();
        return;
      }
      final body =
          jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      requests.add(body);

      // Responses API (built-in web search) vs chat completions.
      final isResponses = req.uri.path == '/responses';
      if (errorStatus != null &&
          (errorPath == null || req.uri.path == errorPath)) {
        req.response.statusCode = errorStatus!;
        req.response.write(errorBody ?? '');
        await req.response.close();
        return;
      }

      req.response
        ..statusCode = 200
        ..headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
      if (isResponses) {
        String event(String type, [Map<String, dynamic>? extra]) => jsonEncode({
              'type': type,
              'sequence_number': 1,
              ...?extra,
            });
        req.response.write('data: ${event('response.created')}\n\n');
        for (final c in chunks) {
          req.response.write(
              'data: ${event('response.output_text.delta', {'delta': c})}\n\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        req.response.write('data: ${event('response.completed')}\n\n');
      } else {
        // Role-only chunk, then content chunks, then [DONE]. The chunk must
        // carry id/object/created/model or async-openai cannot deserialize it.
        String chunk(Map<String, dynamic> delta) => jsonEncode({
              'id': 'chatcmpl-test',
              'object': 'chat.completion.chunk',
              'created': 1234567890,
              'model': 'mock-model',
              'choices': [
                {'delta': delta, 'index': 0},
              ],
            });
        req.response.write('data: ${chunk({'role': 'assistant'})}\n\n');
        for (final c in chunks) {
          req.response.write('data: ${chunk({'content': c})}\n\n');
          await req.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        req.response.write('data: [DONE]\n\n');
      }
      await req.response.close();
    });
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/v1';

  Future<void> stop() => server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await initIsolatedCore();
    File('/tmp/test.pdf').writeAsStringSync(
        buildMinimalPdf('Dummy PDF for RBWA AI tests'));
  });



  test('include_book_history=false drops the thread history', () async {
    final mock = MockOpenAi(chunks: ['答']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'mock-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      webSearchEnabled: false,
      searchUseBuiltin: false,
      ocrMode: 'high_precision',
      includeBookHistory: false,
      enableReasoning: false,
      reasoningEffort: 'medium',
      temperature: 0.7,
      promptTemplate: 'general',
      customPrompt: '',
      customPrompts: const [],
    ));

    final done = Completer<void>();
    rust
        .streamChat(
          action: AiActionType.chat,
          text: 'q2',
          history: [
            AiMessage(
                id: -1,
                threadId: -1,
                role: AiRole.user,
                content: 'q1',
                createdAt: ''),
            AiMessage(
                id: -1,
                threadId: -1,
                role: AiRole.assistant,
                content: 'a1',
                createdAt: ''),
          ],
        )
        .listen((_) {},
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 20));

    // Only the system prompt + the current message reach the API: the
    // thread history is dropped (independent turns).
    final messages =
        (mock.requests.single['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages.length, 2);
    expect(messages.first['role'], 'system');
    expect(messages.last['content'], 'q2');
    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('prompt template prepends the role segment to the action prompt',
      () async {
    final mock = MockOpenAi(chunks: ['答']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'mock-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      webSearchEnabled: false,
      searchUseBuiltin: false,
      ocrMode: 'high_precision',
      includeBookHistory: true,
      enableReasoning: false,
      reasoningEffort: 'medium',
      temperature: 0.7,
      promptTemplate: 'academic',
      customPrompt: '',
      customPrompts: const [],
    ));

    final done = Completer<void>();
    rust
        .streamChat(
          action: AiActionType.translate,
          text: 'hi',
          history: const [],
        )
        .listen((_) {},
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future.timeout(const Duration(seconds: 20));

    final messages =
        (mock.requests.single['messages'] as List).cast<Map<String, dynamic>>();
    final system = messages.first['content'] as String;
    // Role segment first, action instructions kept after it.
    expect(system, contains('学术阅读助手'));
    expect(system, contains('翻译'));
    expect(system.indexOf('学术'), lessThan(system.indexOf('翻译')));
    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('stream_chat streams chunks and builds the right request', () async {
    final mock = MockOpenAi(chunks: ['你好', '，', '世界']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'mock-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      webSearchEnabled: false,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
      searchUseBuiltin: false,
    ));

    final chunks = <String>[];
    final done = Completer<void>();
    rust
        .streamChat(
          action: AiActionType.translate,
          text: 'hello',
          history: const [],
        )
        .listen(chunks.add,
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future;
    expect(chunks.join(), '你好，世界');

    // Request shape: model, stream, system prompt + user message.
    final req = mock.requests.single;
    expect(req['model'], 'mock-model');
    expect(req['stream'], true);
    final messages = (req['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages.first['role'], 'system');
    expect(messages.first['content'] as String, contains('翻译'));
    expect(messages.first['content'] as String, contains('中文'));
    expect(messages.last['role'], 'user');
    expect(messages.last['content'], 'hello');

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('stream_vision_png streams chunks and sends the PNG as a data URL',
      () async {
    final mock = MockOpenAi(chunks: ['识别', '结果']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'mock-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      webSearchEnabled: false,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
      searchUseBuiltin: false,
    ));

    // A tiny "PNG" (any bytes) -- what matters is the data URL encoding.
    const png = [0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
    final chunks = <String>[];
    final done = Completer<void>();
    rust.streamVisionPng(png: png).listen(chunks.add,
        onError: (Object _) { if (!done.isCompleted) done.complete(); },
        onDone: done.complete);
    await done.future;
    expect(chunks.join(), '识别结果');

    // Request shape: the vision model + the screenshot as a data URL, and no
    // `detail` field anywhere (providers reject it).
    final req = mock.requests.single;
    expect(req['model'], 'mock-vision');
    expect(req['stream'], true);
    final messages = (req['messages'] as List).cast<Map<String, dynamic>>();
    expect(messages.first['role'], 'system');
    expect(messages.last['role'], 'user');
    final user = (messages.last['content'] as List)
        .cast<Map<String, dynamic>>();
    expect(user[0]['type'], 'text');
    expect(user[0]['text'] as String, contains('识别'));
    expect(user[1]['type'], 'image_url');
    final url =
        (user[1]['image_url'] as Map<String, dynamic>)['url'] as String;
    expect(url, 'data:image/png;base64,iVBORwECAw==');
    expect(req.toString(), isNot(contains('detail')));

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('AI conversation windows persist per book (6.5.4)', () async {
    // A window bound to a book (any book id; there is no FK to books -- the
    // conversation survives book deletion).
    final res = await rust.createAiThread(
      title: '三体',
      actionType: AiActionType.chat,
      bookId: 42,
    );
    expect(res.id, greaterThan(0));
    expect(res.error, isNull);
    var threads = await rust.listAiThreads();
    expect(threads.single.bookId, 42);
    expect(threads.single.title, '三体');

    // Messages append in order and refresh the latest action (icon after
    // restart shows the most recent action).
    await rust.appendAiMessage(
      threadId: res.id,
      role: AiRole.user,
      content: 'q1',
      actionType: AiActionType.chat,
    );
    await rust.appendAiMessage(
      threadId: res.id,
      role: AiRole.assistant,
      content: 'a1',
      actionType: AiActionType.vision,
    );
    final msgs = await rust.listAiMessages(threadId: res.id);
    expect(msgs.map((m) => m.content).toList(), ['q1', 'a1']);
    threads = await rust.listAiThreads();
    expect(threads.single.actionType, AiActionType.vision);

    // A vision screenshot (识图) is written to disk; history reloads resolve
    // the row to the absolute path of the stored PNG.
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
    );
    await rust.appendAiMessage(
      threadId: res.id,
      role: AiRole.user,
      content: '（区域截图）',
      imagePng: pngBytes,
    );
    final withImage = await rust.listAiMessages(threadId: res.id);
    final vision = withImage.last;
    expect(vision.imagePath, isNotNull);
    final imageFile = File(vision.imagePath!);
    expect(imageFile.existsSync(), isTrue);
    expect(imageFile.readAsBytesSync(), pngBytes);

    // One window per book is enforced in the database.
    final dup = await rust.createAiThread(
      title: '重复',
      actionType: AiActionType.chat,
      bookId: 42,
    );
    expect(dup.id, -1);
    expect(dup.error, isNotNull);

    // The no-book window has a null book id.
    final noBook = await rust.createAiThread(
      title: '未打开书籍',
      actionType: AiActionType.chat,
      bookId: null,
    );
    expect(noBook.id, greaterThan(0));
    final all = await rust.listAiThreads();
    expect(all.map((t) => t.bookId).toSet(), {42, null});

    // Per-window deletion (messages cascade; the screenshot file is removed
    // from disk together with its row).
    expect(imageFile.existsSync(), isTrue);
    expect(await rust.deleteAiThread(threadId: res.id), 1);
    expect(imageFile.existsSync(), isFalse);
    expect(await rust.deleteAiThread(threadId: res.id), 0);
    expect((await rust.listAiThreads()).map((t) => t.id).toSet(),
        {noBook.id});

    // Cleanup so later tests see an empty history.
    for (final t in await rust.listAiThreads()) {
      await rust.deleteAiThread(threadId: t.id);
    }
    expect(await rust.listAiThreads(), isEmpty);
  });

  test('search with web enabled but no search key falls back to knowledge prompt',
      () async {
    // web_search_enabled = true, search_api_key = null: no Bocha call is
    // possible, so the system prompt must say so and answer from knowledge.
    final mock = MockOpenAi(chunks: ['（要点）']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'mock-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      searchApiKey: null,
      webSearchEnabled: true,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
      searchUseBuiltin: false,
    ));

    final done = Completer<void>();
    rust
        .streamChat(action: AiActionType.search, text: '量子计算', history: const [])
        .listen((_) {},
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future;

    final req = mock.requests.single;
    final messages = (req['messages'] as List).cast<Map<String, dynamic>>();
    final system = messages.first['content'] as String;
    expect(system, contains('未配置联网搜索'), reason: 'no-key fallback prompt');
    expect(system, contains('已有知识'));
    expect(mock.requests.length, 1, reason: 'no Bocha call without a key');

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('builtin web search streams from the Responses API endpoint', () async {
    final mock = MockOpenAi(chunks: ['要点一', '要点二']);
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'deepseek-v4-flash',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      searchUseBuiltin: true,
      webSearchEnabled: true,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
    ));

    final chunks = <String>[];
    final done = Completer<void>();
    rust
        .streamChat(action: AiActionType.search, text: '量子计算', history: const [])
        .listen(chunks.add,
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future;
    expect(chunks.join(), '要点一要点二');

    // Hit /responses (the /v1 suffix is stripped) with the web_search tool
    // forced so the provider runs the search server-side.
    expect(mock.requestPaths.single, '/responses');
    final req = mock.requests.single;
    expect(req['model'], 'deepseek-v4-flash');
    expect(req['stream'], true);
    expect(req['instructions'] as String, contains('联网搜索'));
    expect((req['tools'] as List).single, {'type': 'web_search'});
    expect(req['tool_choice'], {'type': 'web_search'});
    final input = (req['input'] as List).cast<Map<String, dynamic>>();
    expect(input.last['role'], 'user');
    expect(input.last['content'], '量子计算');

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('builtin search failure falls back to knowledge noting the error',
      () async {
    // /responses answers 500; the fallback chat-completions call succeeds.
    final mock = MockOpenAi(
      chunks: const ['（知识回答）'],
      errorStatus: 500,
      errorBody: 'search service down',
      errorPath: '/responses',
    );
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'deepseek-v4-flash',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      searchUseBuiltin: true,
      webSearchEnabled: true,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
    ));

    final chunks = <String>[];
    final done = Completer<void>();
    rust
        .streamChat(action: AiActionType.search, text: '量子', history: const [])
        .listen(chunks.add,
            onError: (Object _) { if (!done.isCompleted) done.complete(); },
            onDone: done.complete);
    await done.future;
    expect(chunks.join(), '（知识回答）');

    // The failed search degraded to a knowledge answer whose system prompt
    // names the search error (no silent fallback).
    expect(mock.requestPaths, ['/responses', '/v1/chat/completions']);
    final fallback = mock.requests.last;
    final messages =
        (fallback['messages'] as List).cast<Map<String, dynamic>>();
    final system = messages.first['content'] as String;
    expect(system, contains('联网搜索失败'));
    expect(system, contains('500'));

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('stream_chat surfaces the provider error body on HTTP 400', () async {
    // Simulate a provider rejecting the request (e.g. unknown model): the
    // hand-written client must pass the error body through to the UI.
    final mock = MockOpenAi(
      chunks: const [],
      errorStatus: 400,
      errorBody:
          '{"error":{"message":"Model Not Exist","type":"invalid_request_error"}}',
    );
    await mock.start();
    await rust.setAiConfig(config: AiConfig(
      baseUrl: mock.baseUrl,
      apiKey: 'test-key',
      textModel: 'bad-model',
      visionModel: 'mock-vision',
      visionBaseUrl: null,
      visionApiKey: null,
      translateTargetLang: '中文',
      webSearchEnabled: false,
      ocrMode: 'high_precision',

      includeBookHistory: true,

      enableReasoning: false,

      reasoningEffort: 'medium',

      temperature: 0.7,

      promptTemplate: 'general',

      customPrompt: '',
      customPrompts: const [],
      searchUseBuiltin: false,
    ));

    final done = Completer<void>();
    String? error;
    rust
        .streamChat(action: AiActionType.chat, text: 'hi', history: const [])
        .listen((_) {},
            onError: (Object e) {
              error = e.toString();
              if (!done.isCompleted) done.complete();
            },
            onDone: () {
              if (!done.isCompleted) done.complete();
            });
    await done.future;

    expect(error, isNotNull);
    expect(error, contains('400'), reason: 'status code visible: $error');
    expect(error, contains('Model Not Exist'),
        reason: 'provider message must reach the UI: $error');

    await mock.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));


}
