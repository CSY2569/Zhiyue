import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/src/rust/api.dart' show OcrMode;
import 'package:rbwa/src/rust/models/ai.dart' show AiConfig;
import 'package:rbwa/src/rust/ocr.dart' show OcrResult;

/// The configured OCR model set ("fast" -> fast, anything else -> high
/// precision), kept in sync with the settings page (7.1.9). Shared by the
/// scan state machine and the char-box cache so both always read the same
/// mode.
OcrMode ocrModeFromConfig(AiConfig cfg) =>
    cfg.ocrMode == 'fast' ? OcrMode.fast : OcrMode.highPrecision;

/// Resolve the configured OCR mode, waiting for the async config load
/// (defaults to high precision when unavailable).
Future<OcrMode> configuredOcrMode(Ref ref) async {
  try {
    return ocrModeFromConfig(await ref.read(aiConfigProvider.future));
  } catch (_) {
    return OcrMode.highPrecision;
  }
}

/// The cached OCR result for [page] in either model set: the configured one
/// first, then the other -- switching 高精度/快速 in settings must not make
/// already-scanned pages lose their text layer (7.1.3/7.1.4).
Future<OcrResult?> cachedOcrAnyMode(Ref ref, int bookId, int page) async {
  try {
    final mode = await configuredOcrMode(ref);
    final fallback =
        mode == OcrMode.fast ? OcrMode.highPrecision : OcrMode.fast;
    final repo = ref.read(readerRepositoryProvider);
    return await repo.getPageOcr(bookId, page, mode) ??
        await repo.getPageOcr(bookId, page, fallback);
  } catch (_) {
    return null;
  }
}
