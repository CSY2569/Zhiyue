import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' show OcrMode;

/// Scan state machine per page (FEATURES 7.1.2): pages without a text layer
/// show the "扫描识别" prompt; scanning runs the engine and lands in success /
/// empty / error. The engine returns an explicit "模型未安装" error until
/// scripts/download_ocr_models.sh has run (FEATURES 7.1.1).
enum ScanPhase {
  /// Page has a native text layer: no prompt.
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

/// One page's scan lifecycle. States are per page (0-indexed) so every page
/// in view -- both halves of a spread -- can show its own prompt and be
/// scanned independently (double-page modes, FEATURES 3.1.2 / 3.1.3).
class PageScanState {
  const PageScanState({
    required this.phase,
    this.error,
    this.lowConfidence = 0,
  });

  final ScanPhase phase;
  final String? error;

  /// Lines below the review threshold in the last successful scan (7.1.6).
  final int lowConfidence;

  PageScanState copyWith({
    ScanPhase? phase,
    String? error,
    bool clearError = false,
    int? lowConfidence,
  }) {
    return PageScanState(
      phase: phase ?? this.phase,
      error: clearError ? null : (error ?? this.error),
      lowConfidence: lowConfidence ?? this.lowConfidence,
    );
  }
}

class ScanState {
  const ScanState({
    required this.bookId,
    required this.currentPage, // 1-indexed (viewer space)
    this.pages = const {},
  });

  final int bookId;

  /// The viewer's current page: the auto-detection anchor. Every page the
  /// reader can see gets checked (current page + its right neighbour, which
  /// covers both single and double-page modes).
  final int currentPage;

  /// Per-page scan state, keyed by 0-indexed page.
  final Map<int, PageScanState> pages;

  PageScanState? of(int page) => pages[page];

  ScanState copyWith({
    int? bookId,
    int? currentPage,
    Map<int, PageScanState>? pages,
  }) {
    return ScanState(
      bookId: bookId ?? this.bookId,
      currentPage: currentPage ?? this.currentPage,
      pages: pages ?? this.pages,
    );
  }
}

class ScanNotifier extends Notifier<ScanState> {
  ReaderRepository get _repo => ref.read(readerRepositoryProvider);

  /// Track the open book + current page: page flips re-check the text layer
  /// of the pages in view.
  @override
  ScanState build() {
    final bookId = ref.watch(viewerProvider.select((s) => s.book?.id));
    final page = ref.watch(viewerProvider.select((s) => s.currentPage));
    final state = ScanState(bookId: bookId ?? -1, currentPage: page);
    if (bookId != null) {
      _check(bookId, page);
    }
    return state;
  }

  /// Whether the pages in view have a native text layer (7.1.2 detection):
  /// the current page plus its right neighbour, covering both single and
  /// double-page modes (in a spread the current page is the left half).
  void _check(int bookId, int page1) {
    for (final p0 in {page1 - 1, page1}) {
      _checkPage(bookId, p0);
    }
  }

  /// Detect one page (0-indexed). Pages with an established state are left
  /// untouched: prompts survive page flips until acted on (7.1.2). The
  /// state read happens after the await so it never runs mid-build.
  Future<void> _checkPage(int bookId, int page0) async {
    try {
      final hasText = await _repo.pageHasText(bookId, page0);
      if (state.of(page0) != null) return; // changed while awaiting
      _set(page0, PageScanState(
        phase: hasText ? ScanPhase.hasText : ScanPhase.prompt,
      ));
    } catch (_) {
      // Check failure: stay quiet (hasText) rather than nag the reader.
    }
  }

  void _set(int page0, PageScanState pageState) {
    state = state.copyWith(
      pages: {...state.pages, page0: pageState},
    );
  }

  /// Run the full-page scan of [page0] (7.1.2 / 7.1.8): original resolution
  /// -> engine -> cache, using the configured model set (7.1.9: high
  /// precision or fast). On success the char-box cache is invalidated so the
  /// OCR text layer becomes selectable (7.1.3).
  Future<void> scan(int page0) async {
    if (state.of(page0)?.phase == ScanPhase.scanning) return;
    _set(page0, const PageScanState(phase: ScanPhase.scanning));
    try {
      final mode = await _ocrMode();
      final res = await _repo.scanPage(state.bookId, page0, mode);
      if (res.error != null) {
        _set(page0, PageScanState(phase: ScanPhase.error, error: res.error));
        return;
      }
      ref.invalidate(charBoxCacheProvider);
      _set(page0, PageScanState(
        phase: res.lines.isEmpty ? ScanPhase.empty : ScanPhase.success,
        // 7.1.6: count lines below the review threshold so the UI can ask
        // the reader to double-check them.
        lowConfidence: res.lines
            .where((l) => l.confidence < _lowConfidenceThreshold)
            .length,
      ));
    } catch (e) {
      _set(page0, PageScanState(phase: ScanPhase.error, error: e.toString()));
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

  /// Hide the prompt for [page0].
  void dismiss(int page0) {
    final p = state.of(page0);
    if (p == null) return;
    _set(page0, p.copyWith(phase: ScanPhase.dismissed));
  }
}

/// Confidence below which a recognized line is flagged for review (7.1.6).
const double _lowConfidenceThreshold = 0.8;

/// Full-page scan state, per page of the open book.
final scanStateProvider = NotifierProvider<ScanNotifier, ScanState>(
  ScanNotifier.new,
);
