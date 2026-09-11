import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/settings/settings_page.dart';

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_translation_repo.dart';

class _FakeSettings extends SettingsRepository {
  final _values = <String, String>{};
  @override
  Future<String?> getSetting(String key) async => _values[key];
  @override
  Future<int> setSetting(String key, String value) async {
    _values[key] = value;
    return 1;
  }
}

void main() {
  for (final width in [560.0, 700.0, 900.0, 1400.0]) {
    testWidgets('settings page lays out without overflow at ${width.toInt()}px',
        (tester) async {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(FakeAiRepo()),
            translationRepositoryProvider
                .overrideWithValue(FakeTranslationRepo()),
            settingsRepositoryProvider.overrideWithValue(_FakeSettings()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
