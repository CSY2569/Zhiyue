import 'dart:typed_data' show Uint8List;

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/providers/ai_state.dart' show AiChatMessage;
import 'package:rbwa/src/rust/api.dart' show AiThreadCreateResult;
import 'package:rbwa/src/rust/models/ai.dart';

/// Fake AI repository for widget tests: no Rust, fixed config, streaming
/// answers from a list, and an in-memory thread store mirroring the
/// persisted API (6.5.4). Shared by the AI UI and screenshot tests.
class FakeAiRepo extends AiRepository {
  final sent = <(AiActionType, String)>[];
  AiConfig? saved;
  bool failStream = false;

  /// OCR model set served by [getAiConfig] (7.1.9); tests flip this to
  /// verify the scan pipeline follows the setting.
  String ocrMode = 'high_precision';

  /// In-memory "database": thread id -> (title, messages).
  final savedThreads = <int, String>{};
  final savedBookIds = <int, int?>{};
  final savedMessages = <int, List<AiChatMessage>>{};
  int _nextThreadId = 1;

  /// Copies of the screenshots appended via [appendAiMessage] (a real
  /// persistence layer would write them to disk; the fake just keeps them).
  final savedImages = <int, List<Uint8List>>{};

  @override
  Future<AiConfig> getAiConfig() async => AiConfig(
        baseUrl: 'http://mock/v1',
        apiKey: 'mock-key',
        textModel: 'mock-text',
        visionModel: 'mock-vision',
        visionBaseUrl: null,
        visionApiKey: null,
        translateTargetLang: '中文',
        webSearchEnabled: true,
        searchUseBuiltin: false,
        ocrMode: ocrMode,
        includeBookHistory: true,
        enableReasoning: false,
        reasoningEffort: 'medium',
        temperature: 0.7,
        promptTemplate: 'general',
        customPrompt: '',
        customPrompts: const [],
        templateOverrides: const {},
      );

  @override
  Future<int> setAiConfig(AiConfig config) async {
    saved = config;
    return 1;
  }

  @override
  Future<String> templateDefaultText(String templateId) async =>
      templateId == 'academic' ? '默认学术文本' : '';

  @override
  Future<List<AiThread>> listAiThreads() async => [
        for (final e in savedThreads.entries)
          AiThread(
            id: e.key,
            title: e.value,
            actionType: AiActionType.chat,
            bookId: null,
            createdAt: '',
            updatedAt: '',
          ),
      ];

  @override
  Future<List<AiMessage>> listAiMessages(int threadId) async => [
        for (final m in savedMessages[threadId] ?? const <AiChatMessage>[])
          AiMessage(
            id: -1,
            threadId: threadId,
            role: m.role,
            content: m.content,
            createdAt: '',
            imagePath: m.imagePath,
          ),
      ];

  @override
  Future<AiThreadCreateResult> createAiThread({
    required String title,
    required AiActionType actionType,
    required int? bookId,
  }) async {
    final id = _nextThreadId++;
    savedThreads[id] = title;
    savedBookIds[id] = bookId;
    savedMessages[id] = [];
    return AiThreadCreateResult(id: id, error: null);
  }

  @override
  Future<int> appendAiMessage({
    required int threadId,
    required AiRole role,
    required String content,
    Uint8List? imagePng,
    AiActionType? actionType,
  }) async {
    final list = savedMessages[threadId] ??= [];
    list.add(AiChatMessage(
      role: role,
      content: content,
      imagePng: imagePng,
      actionType: actionType,
      // A real persistence layer writes the PNG to disk and returns the
      // absolute path on reload; the fake mirrors that with a stable id.
      imagePath:
          imagePng != null ? '/fake/ai_images/$threadId-${list.length}.png' : null,
    ));
    if (imagePng != null) {
      (savedImages[threadId] ??= []).add(imagePng);
    }
    return 1;
  }

  final deletedThreads = <int>[];

  @override
  Future<int> deleteAiThread(int threadId) async {
    deletedThreads.add(threadId);
    savedThreads.remove(threadId);
    savedBookIds.remove(threadId);
    savedMessages.remove(threadId);
    return 1;
  }

  @override
  Stream<String> streamChat({
    required AiActionType action,
    required String text,
    required List<AiMessage> history,
  }) {
    sent.add((action, text));
    if (failStream) {
      return Stream.error(Exception('HTTP 400: Model Not Exist'));
    }
    return Stream.fromIterable(['答', '案']);
  }

  final visionCalls = <Uint8List>[];

  /// Chunks streamed by [streamVisionPng]; tests pin the exact answer they
  /// assert (e.g. '识别结果' in the screenshot test, '答案' in the AI UI test).
  List<String> visionChunks = const ['识别', '结果'];

  @override
  Stream<String> streamVisionPng({required Uint8List png}) {
    visionCalls.add(png);
    if (failStream) {
      return Stream.error(Exception('HTTP 400: Model Not Exist'));
    }
    return Stream.fromIterable(visionChunks);
  }
}
