import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/ai.dart';

import 'helpers/smoke_helpers.dart';

/// End-to-end check of the SELECTION translate path (划词翻译) through the
/// real core: configure an OpenAI-compatible mock that streams SSE, call
/// `streamChat(action: translate)`, and assert the answer arrives.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  final requests = <String>[];

  setUpAll(() async {
    await initIsolatedCore();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in server) {
        final body = await utf8.decoder.bind(req).join();
        requests.add(body);
        // Minimal OpenAI-compatible SSE stream.
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'event-stream');
        final sse = [
          'data: {"choices":[{"delta":{"content":"量子"}}]}\n\n',
          'data: {"choices":[{"delta":{"content":"世界"}}]}\n\n',
          'data: [DONE]\n\n',
        ].join();
        req.response.add(utf8.encode(sse));
        await req.response.close();
      }
    }());
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('streamChat translate returns the streamed answer', () async {
    final base = 'http://127.0.0.1:${server.port}/v1';
    await rust.setSetting(
      key: 'ai_config',
      value: jsonEncode({
        'base_url': base,
        'api_key': 'test-key',
        'text_model': 'mock-model',
        'translate_target_lang': '中文',
        'api_protocol': 'chat_completions',
      }),
    );

    final chunks = <String>[];
    Object? err;
    try {
      await for (final c in rust.streamChat(
        action: AiActionType.translate,
        text: 'The quantum world',
        history: const [],
        isFollowUp: false,
      )) {
        chunks.add(c);
      }
    } catch (e) {
      err = e;
    }
    // ignore: avoid_print
    print('CHUNKS: $chunks  ERR: $err  REQS: ${requests.length}');
    expect(err, isNull, reason: 'stream error: $err');
    expect(requests, isNotEmpty, reason: 'mock never called');
    expect(chunks.join(), '量子世界');
  });
}
