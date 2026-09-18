import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/engine_provider.dart';
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
  testWidgets('未安装时显示下载开关与体积说明', (tester) async {
    final repo = FakeTranslationRepo();
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    expect(find.text('翻译引擎'), findsOneWidget);
    expect(find.text('未安装'), findsOneWidget);
    expect(find.text('未启用'), findsOneWidget);
    expect(find.textContaining('约 1GB'), findsOneWidget);
    expect(find.textContaining('AGPL-3.0'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('打开开关→确认→安装完成→显示已安装与占用', (tester) async {
    final repo = FakeTranslationRepo()
      // install() re-reads the status afterwards; report the installed state.
      ..engineStatus = const EngineStatus(
        kind: EngineStatusKind.notInstalled,
        phase: '',
        progress: 0,
        version: '',
        sizeBytes: 0,
        error: null,
      );
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    // Flip the switch -> confirmation dialog.
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('下载翻译引擎'), findsOneWidget);

    // Simulate the disk state that install() will read back.
    repo.engineStatus = const EngineStatus(
      kind: EngineStatusKind.installed,
      phase: '',
      progress: 1,
      version: '2.9.0',
      sizeBytes: 1153433600, // ~1.07 GB
      error: null,
    );
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();

    expect(repo.installCalls, 1);
    expect(find.text('已安装'), findsOneWidget);
    expect(find.textContaining('v2.9.0'), findsOneWidget);
    expect(find.textContaining('1.1 GB'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('安装中显示进度与取消；失败显示重试', (tester) async {
    final repo = FakeTranslationRepo();
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();

    // Drive the controller directly to the installing state.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EngineSettingsCard)),
      listen: false,
    );
    container.read(engineStatusProvider.notifier).state = const AsyncData(
      EngineStatus(
        kind: EngineStatusKind.installing,
        phase: '安装依赖',
        progress: 0.25,
        version: '',
        sizeBytes: 0,
        error: null,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('安装依赖'), findsOneWidget);
    expect(find.textContaining('25%'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // Failure state offers a retry.
    container.read(engineStatusProvider.notifier).state = const AsyncData(
      EngineStatus(
        kind: EngineStatusKind.failed,
        phase: '',
        progress: 0,
        version: '',
        sizeBytes: 0,
        error: '网络不可达',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('失败'), findsOneWidget);
    expect(find.textContaining('网络不可达'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('关闭开关→确认→调用卸载', (tester) async {
    final repo = FakeTranslationRepo()
      ..engineStatus = const EngineStatus(
        kind: EngineStatusKind.installed,
        phase: '',
        progress: 1,
        version: '2.9.0',
        sizeBytes: 1024,
        error: null,
      );
    await tester.pumpWidget(_scope(repo));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('卸载翻译引擎'), findsOneWidget);
    await tester.tap(find.text('卸载'));
    await tester.pumpAndSettle();

    expect(repo.uninstallCalls, 1);
    expect(find.text('未安装'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });
}