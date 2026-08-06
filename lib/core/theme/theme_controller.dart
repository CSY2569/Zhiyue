import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

/// Theme mode preference (FEATURES 8.2 / 8.3).
///
/// Persisted to the `settings` table via the Rust core (`theme` key). The
/// skeleton reads/writes through the FRB `getSetting` / `setSetting` helpers;
/// M1 will replace these with a proper settings repository.
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
      final raw = await rust.getSetting(key: _key);
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
      await rust.setSetting(key: _key, value: mode.name);
    } catch (_) {
      // Persistence failure is non-fatal for the skeleton.
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
