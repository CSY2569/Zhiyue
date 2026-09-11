import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

import 'helpers/smoke_helpers.dart';

/// Regression for the bilingual-reading "API never called / translation never
/// shown" failures, through the REAL compiled core:
///
/// 1. `getTranslationOverview` used to self-deadlock the core's DB mutex (the
///    reader calls it on every book open). Any dependent call then hung forever.
/// 2. With 中英互译, rows were written under the per-page effective language
///    (中文/英文) but read under the configured key (中英互译), so a translated
///    page was never found.
///
/// Uses a mock LLM; the user's real key is never touched.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;

  setUpAll(() async {
    File('/tmp/bilingual-overview-book.pdf').writeAsStringSync(
      buildMinimalPdf('The quantum world is strange.'),
    );
    await initIsolatedCore();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(() async {
      await for (final req in server) {
        await utf8.decoder.bind(req).join();
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

  test('overview returns and 中英互译 translations are found again', () async {
    final imp = await rust.importBook(path: '/tmp/bilingual-overview-book.pdf');
    expect(imp.error, isNull, reason: '${imp.error}');
    final bookId = imp.book!.id.toInt();

    await rust.setSetting(
      key: 'ai_config',
      value: jsonEncode({
        'base_url': 'http://127.0.0.1:${server.port}/v1',
        'api_key': 'test-key',
        'text_model': 'mock-model',
        // The user's real setting: bilingual mode.
        'translate_target_lang': '中英互译',
      }),
    );
    await rust.setSetting(
      key: 'translation_config',
      value: jsonEncode({'provider': 'ReuseAi', 'mode': 'WithProgress'}),
    );

    // 1. The reader's book-open call must not hang.
    final overview = await rust
        .getTranslationOverview(bookId: bookId)
        .timeout(const Duration(seconds: 10));
    expect(overview.error, isNull, reason: '${overview.error}');
    expect(overview.translatedPages, 0);

    // Translate a page (effective language for this English page is 中文).
    await for (final _ in rust.translatePage(
      bookId: bookId,
      page: 1,
      force: false,
    )) {}

    // 2. The row must be found under the configured 中英互译 key.
    final got = await rust.getPageTranslation(bookId: bookId, page: 1);
    expect(got.error, isNull, reason: '${got.error}');
    expect(got.translation, isNotNull,
        reason: '中英互译 cache row was not found under the configured key');
    expect(got.translation!.targetLang, '中文',
        reason: 'effective language must stay in the payload');

    final overview2 = await rust
        .getTranslationOverview(bookId: bookId)
        .timeout(const Duration(seconds: 10));
    expect(overview2.translatedPages, 1,
        reason: 'overview must count the 中英互译 row');

    // 3. The page-level render channel must see it too.
    final bmp = await rust.renderTranslatedPage(
      bookId: bookId,
      page: 1,
      targetLang: '中英互译',
      dpiScale: 1.0,
    );
    expect(bmp.error, isNull, reason: '${bmp.error}');
    expect(bmp.hasTranslation, isTrue);
    expect(bmp.width, greaterThan(0));
  });
}
