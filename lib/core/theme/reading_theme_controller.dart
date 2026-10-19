import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/settings/settings_store.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';

/// Reading-theme preference (FEATURES 8.11): 纸白 / 羊皮纸 / 暗夜 / 跟随亮度.
///
/// Persisted to the `settings` KV table via [SettingsRepository]
/// (`reading_theme` key), mirroring [ThemeController]: hydrate async,
/// persistence failures are non-fatal. The app root resolves this into the
/// app-wide theme (see `app.dart`).
class ReadingThemeController extends Notifier<ReadingTheme> {
  static const _key = 'reading_theme';

  @override
  ReadingTheme build() {
    _hydrate();
    return ReadingTheme.auto;
  }

  Future<void> _hydrate() async {
    final value = await loadSetting(
      ref.read(settingsRepositoryProvider),
      _key,
      parseReadingTheme,
    );
    if (value != null) state = value;
  }

  Future<void> set(ReadingTheme theme) async {
    state = theme;
    await persistSetting(
      ref.read(settingsRepositoryProvider),
      _key,
      theme.name,
    );
  }
}

/// Riverpod provider for the reading-theme preference.
final readingThemeControllerProvider =
    NotifierProvider<ReadingThemeController, ReadingTheme>(
        ReadingThemeController.new);
