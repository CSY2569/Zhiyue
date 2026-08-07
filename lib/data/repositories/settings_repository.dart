import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;

/// Wrapper around the raw settings KV store (table: `settings`, FEATURES
/// 9.1.8). High-level settings (theme, AI config) build on this; the UI
/// never touches the FRB layer directly.
class SettingsRepository {
  /// Read a raw setting value; null when the key is absent.
  Future<String?> getSetting(String key) => rust.getSetting(key: key);

  /// Upsert a raw setting value; returns 1 on success.
  Future<int> setSetting(String key, String value) =>
      rust.setSetting(key: key, value: value);
}

/// Riverpod provider for the singleton [SettingsRepository].
final settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) => SettingsRepository());
