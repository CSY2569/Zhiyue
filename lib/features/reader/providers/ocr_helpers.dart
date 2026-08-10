import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/src/rust/api.dart' show OcrMode;
import 'package:rbwa/src/rust/models/ai.dart' show AiConfig;
import 'package:rbwa/src/rust/ocr.dart' show OcrResult;

/// Confidence below which a recognized line is flagged for review (7.1.6).
/// Shared by the scan state machine and the low-confidence marking layer.
const double kLowConfidenceThreshold = 0.8;

/// The configured OCR model set ("fast" -> fast, anything else -> high
/// precision), kept in sync with the settings page (7.1.9). Shared by the
/// scan state machine and the char-box cache so both always read the same
/// mode.
OcrMode ocrModeFromConfig(AiConfig cfg) =>
    cfg.ocrMode == 'fast' ? OcrMode.fast : OcrMode.highPrecision;

/// Resolve the configured OCR mode, waiting for the async config load
/// (defaults to high precision when unavailable). [config] is the awaited
/// AiConfig (the caller resolves it with its own ref type).
Future<OcrMode> configuredOcrMode(Future<AiConfig> config) async {
  try {
    return ocrModeFromConfig(await config);
  } catch (_) {
    return OcrMode.highPrecision;
  }
}

/// The cached OCR result for [page] in either model set: the configured one
/// first, then the other -- switching 高精度/快速 in settings must not make
/// already-scanned pages lose their text layer (7.1.3/7.1.4).
///
/// [repo] and [modeResolver] decouple this from the Riverpod `Ref` type so
/// both Notifiers (whose `ref` is a `Ref`) and widgets (whose `ref` is a
/// `WidgetRef`) can call it: the caller resolves the repository and mode
/// with its own ref type and passes plain values here.
Future<OcrResult?> cachedOcrAnyMode({
  required ReaderRepository repo,
  required Future<OcrMode> Function() modeResolver,
  required int bookId,
  required int page,
}) async {
  try {
    final mode = await modeResolver();
    final fallback =
        mode == OcrMode.fast ? OcrMode.highPrecision : OcrMode.fast;
    return await repo.getPageOcr(bookId, page, mode) ??
        await repo.getPageOcr(bookId, page, fallback);
  } catch (_) {
    return null;
  }
}
