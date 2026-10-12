import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';

import 'helpers/fake_settings.dart';

void main() {
  test('hydrates the stored theme from settings', () async {
    final container = ProviderContainer(overrides: [
      settingsRepositoryProvider
          .overrideWithValue(FakeSettings({'reading_theme': 'parchment'})),
    ]);
    addTearDown(container.dispose);
    // Default before the async hydrate lands.
    expect(container.read(readingThemeControllerProvider), ReadingTheme.auto);
    await Future<void>.delayed(Duration.zero);
    expect(
        container.read(readingThemeControllerProvider), ReadingTheme.parchment);
  });

  test('set updates state and persists', () async {
    final fake = FakeSettings();
    final container = ProviderContainer(overrides: [
      settingsRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);
    await container
        .read(readingThemeControllerProvider.notifier)
        .set(ReadingTheme.night);
    expect(container.read(readingThemeControllerProvider), ReadingTheme.night);
    expect(fake.writes['reading_theme'], 'night');
  });
}
