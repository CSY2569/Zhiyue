import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/widgets/engine_settings_card.dart';
import 'package:rbwa/src/rust/models/translate.dart';

import 'helpers/fake_translation_repo.dart';

ProviderScope _scope(FakeTranslationRepo repo) => ProviderScope(
      overrides: [translationRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: EngineSettingsCard(),
          ),
        ),
      ),
    );

void main() {
  testWidgets('内置引擎显示已内置 / 版本 / 占用', (tester) async {
    final repo = FakeTranslationRepo()
      ..engineStatus = const EngineStatus(
        kind: EngineStatusKind.installed,
        phase: '',
        progress: 1,
        version: 'retainpdf-pipeline 4.2.6',
        sizeBytes: 300312576, // ~286 MB
        error: null,
        bundled: true,
      );
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    expect(find.text('翻译引擎'), findsOneWidget);
    expect(find.text('已内置'), findsOneWidget);
    expect(find.textContaining('retainpdf-pipeline 4.2.6'), findsOneWidget);
    expect(find.textContaining('286 MB'), findsOneWidget);
    expect(find.textContaining('RetainPDF 翻译引擎'), findsOneWidget);
    expect(find.textContaining('简体中文'), findsOneWidget);
    // v1 没有安装/卸载交互。
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('未找到引擎时给出构建指引', (tester) async {
    final repo = FakeTranslationRepo();
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    expect(find.text('未找到'), findsOneWidget);
    expect(
      find.textContaining('scripts/build_retain_engine.sh'),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('开发目录引擎显示“已就绪”而非“已内置”', (tester) async {
    final repo = FakeTranslationRepo()
      ..engineStatus = const EngineStatus(
        kind: EngineStatusKind.installed,
        phase: '',
        progress: 1,
        version: 'retainpdf-pipeline 4.2.6',
        sizeBytes: 1024,
        error: null,
        bundled: false,
      );
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    expect(find.text('已就绪'), findsOneWidget);
    expect(find.textContaining('已就绪（'), findsNothing); // 文案不重复
    expect(find.text('已内置'), findsNothing);
  });
}