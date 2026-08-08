import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' show OcrMode;

/// Scan state machine (FEATURES 7.1.2): a page without a text layer shows
/// the "扫描识别" prompt; scanning runs the engine and lands in success /
/// empty / error. The engine returns an explicit "模型未安装" error until
/// scripts/download_ocr_models.sh has run (FEATURES 7.1.1).
enum ScanPhase {
  /// Page has a native text layer (or the check is still running): no prompt.
  hasText,
  /// No text layer: offer 扫描识别.
  prompt,
  /// Engine running.
  scanning,
  /// Scan succeeded; the OCR text layer is active for this page.
  success,
  /// The engine found no text.
  empty,
  /// Scan failed (e.g. models not installed).
  error,
  /// The user dismissed the prompt for this page.
  dismissed,
}

/// Confidence below which a recognized line is flagged for review (7.1.6).
const double _lowConfidenceThreshold = 0.8;

class ScanState {
  const ScanState({
    required this.phase,
    required this.bookId,
    required this.page, // 1-indexed (viewer space)
    this.error,
    this.lowConfidence = 0,
  });

  final ScanPhase phase;
  final int bookId;
  final int page;
  final String? error;

  /// Lines below the review threshold in the last successful scan (7.1.6).
  final int lowConfidence;

  ScanState copyWith({
    ScanPhase? phase,
    int? bookId,
    int? page,
    String? error,
    bool clearError = false,
    int? lowConfidence,
  }) {
    return ScanState(
      phase: phase ?? this.phase,
      bookId: bookId ?? this.bookId,
      page: page ?? this.page,
      error: clearError ? null : (error ?? this.error),
      lowConfidence: lowConfidence ?? this.lowConfidence,
    );
  }
}

class ScanNotifier extends Notifier<ScanState> {
  ReaderRepository get _repo => ref.read(readerRepositoryProvider);

  /// Track the open book + current page: page flips re-check the text layer.
  @override
  ScanState build() {
    final bookId = ref.watch(viewerProvider.select((s) => s.book?.id));
    final page = ref.watch(viewerProvider.select((s) => s.currentPage));
    final state = ScanState(phase: ScanPhase.hasText, bookId: bookId ?? -1, page: page);
    if (bookId != null) {
      _check(bookId, page);
    }
    return state;
  }

  /// Whether the current page has a native text layer (7.1.2 detection).
  Future<void> _check(int bookId, int page) async {
    try {
      final hasText = await _repo.pageHasText(bookId, page - 1);
      if (state.bookId != bookId || state.page != page) return;
      state = state.copyWith(
        phase: hasText ? ScanPhase.hasText : ScanPhase.prompt,
        clearError: true,
      );
    } catch (_) {
      // Check failure: stay quiet (hasText) rather than nag the reader.
    }
  }

  /// Run the full-page scan (7.1.2 / 7.1.8): original resolution -> engine
  /// -> cache, using the configured model set (7.1.9: high precision or
  /// fast). On success the char-box cache is invalidated so the OCR text
  /// layer becomes selectable (7.1.3).
  Future<void> scan() async {
    if (state.phase == ScanPhase.scanning) return;
    state = state.copyWith(phase: ScanPhase.scanning, clearError: true);
    try {
      final mode = await _ocrMode();
      final res = await _repo.scanPage(state.bookId, state.page - 1, mode);
      if (res.error != null) {
        state = state.copyWith(phase: ScanPhase.error, error: res.error);
        return;
      }
      ref.invalidate(charBoxCacheProvider);
      state = state.copyWith(
        phase: res.lines.isEmpty ? ScanPhase.empty : ScanPhase.success,
        // 7.1.6: count lines below the review threshold so the UI can ask
        // the reader to double-check them.
        lowConfidence: res.lines
            .where((l) => l.confidence < _lowConfidenceThreshold)
            .length,
      );
    } catch (e) {
      state = state.copyWith(phase: ScanPhase.error, error: e.toString());
    }
  }

  /// The configured OCR model set ("fast" -> fast, anything else -> high
  /// precision), kept in sync with the settings page (7.1.9). Waits for the
  /// async config load; defaults to high precision when unavailable.
  Future<OcrMode> _ocrMode() async {
    try {
      final cfg = await ref.read(aiConfigProvider.future);
      return cfg.ocrMode == 'fast' ? OcrMode.fast : OcrMode.highPrecision;
    } catch (_) {
      return OcrMode.highPrecision;
    }
  }

  /// Hide the prompt for the current page.
  void dismiss() => state = state.copyWith(phase: ScanPhase.dismissed);
}

/// Full-page scan state for the open book (auto-resets on page flips).
final scanStateProvider = NotifierProvider<ScanNotifier, ScanState>(
  ScanNotifier.new,
);
