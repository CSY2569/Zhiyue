import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/src/rust/models/translate.dart';

/// Loads / saves the persisted 对照阅读 config (KV `translation_config`,
/// plan §8). Mirrors [AiConfigNotifier]: the settings page edits a draft and
/// calls [save].
class TranslationConfigNotifier extends AsyncNotifier<TranslationConfig> {
  @override
  Future<TranslationConfig> build() =>
      ref.watch(translationRepositoryProvider).getTranslationConfig();

  Future<bool> save(TranslationConfig config) async {
    final ok =
        await ref.read(translationRepositoryProvider).setTranslationConfig(config) >
            0;
    if (ok) state = AsyncValue.data(config);
    return ok;
  }

  /// Sets the whole-book background behaviour (the first-run dialog records
  /// the user's choice here, plan §8 v4.2).
  Future<bool> setBackgroundBehavior(TranslationBackgroundBehavior behavior) async {
    final current = state.valueOrNull;
    if (current == null) return false;
    return save(TranslationConfig(
      provider: current.provider,
      baseUrl: current.baseUrl,
      apiKey: current.apiKey,
      model: current.model,
      sourceLang: current.sourceLang,
      mode: current.mode,
      backgroundBehavior: behavior,
      autoOcr: current.autoOcr,
      concurrency: current.concurrency,
      cacheLimitMb: current.cacheLimitMb,
    ));
  }
}

final translationConfigProvider =
    AsyncNotifierProvider<TranslationConfigNotifier, TranslationConfig>(
        TranslationConfigNotifier.new);
