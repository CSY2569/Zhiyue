import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/settings/settings_page.dart';

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_settings.dart';
import 'helpers/fake_translation_repo.dart';

void main() {
  testWidgets('阅读主题 row persists the selection', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeSettings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiRepositoryProvider.overrideWithValue(FakeAiRepo()),
          translationRepositoryProvider
              .overrideWithValue(FakeTranslationRepo()),
          settingsRepositoryProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('主题模式'), findsNothing,
        reason: 'the old light/dark row was merged into the theme picker');
    await tester.tap(find.text('羊皮纸'));
    await tester.pumpAndSettle();
    expect(fake.writes['reading_theme'], 'parchment');

    await tester.tap(find.text('暗夜'));
    await tester.pumpAndSettle();
    expect(fake.writes['reading_theme'], 'night');
  });
}
