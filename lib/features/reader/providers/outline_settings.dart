import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/settings_repository.dart';

/// Whether the reader's outline (table of contents) sidebar starts with every
/// level expanded (设置 → 阅读器, FEATURES 3.4.2).
///
/// Persisted to the `settings` KV table through the [SettingsRepository]
/// (`outline_expand_all` key), mirroring [ThemeController]. Off (the default)
/// shows only the top-level chapters until the user expands a node; on opens
/// every level up front.
class OutlineExpandAll extends Notifier<bool> {
  static const _key = 'outline_expand_all';

  @override
  bool build() {
    // Start collapsed (the original behavior), then hydrate from the DB.
    _hydrate();
    return false;
  }

  Future<void> _hydrate() async {
    try {
      final raw = await ref.read(settingsRepositoryProvider).getSetting(_key);
      if (raw != null) state = raw == 'true';
    } catch (_) {
      // Core not ready yet (e.g. during tests); keep the default.
    }
  }

  Future<void> set(bool value) async {
    state = value;
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setSetting(_key, value ? 'true' : 'false');
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory value still applies.
    }
  }
}

/// Riverpod provider for the outline "expand all by default" preference.
final outlineExpandAllProvider =
    NotifierProvider<OutlineExpandAll, bool>(OutlineExpandAll.new);
