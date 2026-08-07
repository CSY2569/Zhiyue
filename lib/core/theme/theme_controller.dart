import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/settings_repository.dart';

/// Theme mode preference (FEATURES 8.2 / 8.3).
///
/// Persisted to the `settings` table via the Rust core (`theme` key) through
/// the [SettingsRepository] (ARCHITECTURE §1: UI only talks to repositories).
class ThemeController extends Notifier<ThemeMode> {
  static const _key = 'theme';

  @override
  ThemeMode build() {
    // Start from system, then hydrate asynchronously from the DB.
    _hydrate();
    return ThemeMode.system;
  }

  Future<void> _hydrate() async {
    try {
      final raw = await ref.read(settingsRepositoryProvider).getSetting(_key);
      if (raw != null) {
        state = _parse(raw) ?? ThemeMode.system;
      }
    } catch (_) {
      // Core not ready yet (e.g. during tests); keep system default.
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    try {
      await ref.read(settingsRepositoryProvider).setSetting(_key, mode.name);
    } catch (_) {
      // Persistence failure is non-fatal.
    }
  }

  ThemeMode? _parse(String raw) {
    switch (raw) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return null;
    }
  }
}

/// Riverpod provider for the active theme mode.
final themeControllerProvider =
    NotifierProvider<ThemeController, ThemeMode>(ThemeController.new);
