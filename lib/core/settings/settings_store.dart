import 'package:rbwa/data/repositories/settings_repository.dart';

/// Read + decode a settings value; returns null when absent, malformed or
/// the Rust core is not ready (tests), keeping the caller's default.
Future<T?> loadSetting<T>(
  SettingsRepository repo,
  String key,
  T? Function(String raw) decode,
) async {
  try {
    final raw = await repo.getSetting(key);
    return raw == null ? null : decode(raw);
  } catch (_) {
    return null;
  }
}

/// Persist a settings value. Failures are non-fatal: the in-memory state
/// already reflects the user's choice.
Future<void> persistSetting(
  SettingsRepository repo,
  String key,
  String value,
) async {
  try {
    await repo.setSetting(key, value);
  } catch (_) {
    // Persistence failure is non-fatal.
  }
}
