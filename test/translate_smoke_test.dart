import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/smoke_helpers.dart';

/// End-to-end reproduction of the REAL bilingual-reading path through FRB:
/// isolated DB -> import a synthetic PDF -> configure an OpenAI-compatible
/// mock -> call `translatePage` -> assert the cached translation comes back.
///
/// This is the highest-fidelity check available outside the app itself: it
/// runs the compiled `librbwa_core.so`, so it catches FFI wiring that the
/// pure-widget tests mock out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  final requests = <String>[];

  setUpAll(() async {
    File('/tmp/translate-book.pdf').writeAsStringSync(
      buildMinimalPdf('The quantum world is strange. It follows rules.'),
    );
    await initIsolatedCore();

    // Mock OpenAI-compatible endpoint returning a strictly aligned JSON batch.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in server) {
        final body = await utf8.decoder.bind(req).join();
        requests.add(body);
        final payload = jsonEncode({
          'choices': [
            {
              'message': {
                'content': '[{"i":0,"t":"量子世界很奇妙。"}]',
              }
            }
          ]
        });
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(payload);
        await req.response.close();
      }
    }());
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('translatePage works end to end through the real core', () async {
    final imp = await rust.importBook(path: '/tmp/translate-book.pdf');
    expect(imp.error, isNull, reason: 'import: ${imp.error}');
    final bookId = imp.book!.id.toInt();

    final base = 'http://127.0.0.1:${server.port}/v1';
    await rust.setSetting(
      key: 'ai_config',
      value: jsonEncode({
        'base_url': base,
        'api_key': 'test-key',
        'text_model': 'mock-model',
        'translate_target_lang': '中文',
      }),
    );
    await rust.setSetting(
      key: 'translation_config',
      value: jsonEncode({'provider': 'ReuseAi'}),
    );

    // Extraction must see the page text first.
    final extracted = await rust.extractPageParagraphs(bookId: bookId, page: 1);
    expect(extracted.error, isNull, reason: 'extract: ${extracted.error}');
    expect(extracted.paragraphs, isNotEmpty,
        reason: 'no paragraphs extracted from the fixture');

    final events = <TranslationProgressEvent>[];
    Object? streamError;
    try {
      await for (final ev in rust.translatePage(
        bookId: bookId,
        page: 1,
        force: false,
      )) {
        events.add(ev);
      }
    } catch (e) {
      streamError = e;
    }
    expect(streamError, isNull, reason: 'translate stream error: $streamError');
    expect(events, isNotEmpty, reason: 'no progress events');
    expect(requests, isNotEmpty, reason: 'mock LLM was never called');

    final got = await rust.getPageTranslation(bookId: bookId, page: 1);
    expect(got.error, isNull, reason: 'get: ${got.error}');
    expect(got.translation, isNotNull,
        reason: 'nothing cached after translate_page');
    final translated = got.translation!.paragraphs
        .map((p) => p.translated)
        .where((t) => t.isNotEmpty)
        .toList();
    // ignore: avoid_print
    print('TRANSLATED: $translated');
    expect(translated, contains('量子世界很奇妙。'));

    // The page-level render channel (the pane draws this bitmap).
    final bmp = await rust.renderTranslatedPage(
      bookId: bookId,
      page: 1,
      targetLang: '中文',
      dpiScale: 1.0,
    );
    expect(bmp.error, isNull, reason: 'render: ${bmp.error}');
    expect(bmp.hasTranslation, isTrue, reason: 'page should have a translation');
    expect(bmp.width, greaterThan(0));
    expect(bmp.height, greaterThan(0));
    expect(bmp.rgba.length, bmp.width * bmp.height * 4);

    // A page with no translation reports hasTranslation=false.
    final none = await rust.renderTranslatedPage(
      bookId: bookId,
      page: 999,
      targetLang: '中文',
      dpiScale: 1.0,
    );
    expect(none.hasTranslation, isFalse);
  });
}
