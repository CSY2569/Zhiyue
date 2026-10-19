import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// Loads the persisted BYOK config and exposes `save()` (FEATURES 6.1).
class AiConfigNotifier extends AsyncNotifier<AiConfig> {
  @override
  Future<AiConfig> build() => ref.watch(aiRepositoryProvider).getAiConfig();

  /// Persist the config; updates state on success. Returns false on failure.
  Future<bool> save(AiConfig config) async {
    final ok = await ref.read(aiRepositoryProvider).setAiConfig(config) > 0;
    if (ok) state = AsyncValue.data(config);
    return ok;
  }
}

/// AI configuration for the app (defaults until the user saves).
final aiConfigProvider =
    AsyncNotifierProvider<AiConfigNotifier, AiConfig>(AiConfigNotifier.new);
