import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';

/// Reading-theme preference (FEATURES 8.11): 纸白 / 羊皮纸 / 暗夜 / 跟随亮度.
///
/// Persisted to the `settings` KV table via [SettingsRepository]
/// (`reading_theme` key), mirroring [ThemeController]: hydrate async,
/// persistence failures are non-fatal.
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

/// Applies the effective reading theme to its subtree as a [Theme] override
/// (FEATURES 8.11). Used by the reader route only -- library / settings keep
/// the app-wide light/dark theme. `auto` follows the app brightness.
class ReadingThemeScope extends ConsumerWidget {
  const ReadingThemeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(readingThemeControllerProvider);
    final mode = ref.watch(themeControllerProvider);
    final platform = MediaQuery.platformBrightnessOf(context);
    final effective = resolveReadingTheme(choice, mode, platform);
    return Theme(data: AppTheme.forReadingTheme(effective), child: child);
  }
}
