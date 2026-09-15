import 'package:rbwa/data/repositories/settings_repository.dart';

/// In-memory settings KV for widget tests: reads fall back to [seed],
/// writes are recorded in [writes] (and readable back through getSetting).
class FakeSettings extends SettingsRepository {
  FakeSettings([Map<String, String>? seed]) : _values = {...?seed};
  final Map<String, String> _values;
  final writes = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => _values[key];

  @override
  Future<int> setSetting(String key, String value) async {
    _values[key] = value;
    writes[key] = value;
    return 1;
  }
}