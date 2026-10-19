import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/settings/settings_store.dart';
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
    final value = await loadSetting(
      ref.read(settingsRepositoryProvider),
      _key,
      (raw) => raw == 'true',
    );
    if (value != null) state = value;
  }

  Future<void> set(bool value) async {
    state = value;
    await persistSetting(
      ref.read(settingsRepositoryProvider),
      _key,
      value ? 'true' : 'false',
    );
  }
}

/// Riverpod provider for the outline "expand all by default" preference.
final outlineExpandAllProvider =
    NotifierProvider<OutlineExpandAll, bool>(OutlineExpandAll.new);
