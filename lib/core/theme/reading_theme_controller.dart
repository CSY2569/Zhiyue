import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    try {
      final raw = await ref.read(settingsRepositoryProvider).getSetting(_key);
      if (raw != null) {
        state = parseReadingTheme(raw) ?? ReadingTheme.auto;
      }
    } catch (_) {
      // Core not ready yet (e.g. during tests); keep auto.
    }
  }

  Future<void> set(ReadingTheme theme) async {
    state = theme;
    try {
      await ref.read(settingsRepositoryProvider).setSetting(_key, theme.name);
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory value still applies.
    }
  }
}

/// Riverpod provider for the reading-theme preference.
final readingThemeControllerProvider =
    NotifierProvider<ReadingThemeController, ReadingTheme>(
        ReadingThemeController.new);
