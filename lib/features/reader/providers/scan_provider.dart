import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/reader/providers/ocr_helpers.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/models/progress.dart' show ViewMode;

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
    int? lowConfidence,
  }) {
    return PageScanState(
      phase: phase ?? this.phase,
      error: error ?? this.error,
      lowConfidence: lowConfidence ?? this.lowConfidence,
    );
  }
}

class ScanState {
  const ScanState({
    required this.bookId,
    this.pages = const {},
  });

  final int bookId;

  /// Per-page scan state, keyed by 0-indexed page. Accumulated across page
  /// flips (book switch resets it): prompts / dismissed / error / empty all
  /// survive until the reader acts on them or switches books.
  final Map<int, PageScanState> pages;

  PageScanState? of(int page) => pages[page];

  /// Copies only the per-page map -- bookId is re-derived by `build()` on
  /// book switch.
  ScanState copyWith({Map<int, PageScanState>? pages}) {
    return ScanState(
      bookId: bookId,
      pages: pages ?? this.pages,
    );
  }
}

class ScanNotifier extends Notifier<ScanState> {
  ReaderRepository get _repo => ref.read(readerRepositoryProvider);

  /// Track the open book: switching books resets the per-page state. Page
  /// flips do NOT rebuild this notifier -- they fire `ref.listen` below,
  /// which re-checks the pages now in view without wiping accumulated state
  /// (dismissed / error / empty / success must survive a flip).
  @override
  ScanState build() {
    final bookId = ref.watch(viewerProvider.select((s) => s.book?.id));
    // Re-check the pages in view whenever the reader navigates -- without
    // rebuilding (a rebuild would discard the per-page map).
    ref.listen(viewerProvider.select((s) => s.currentPage), (prev, next) {
      final viewer = ref.read(viewerProvider);
      final id = viewer.book?.id;
      if (id == null) return;
      _check(id, next, viewer.mode, viewer.pageCount);
    });
    final state = ScanState(bookId: bookId ?? -1);
    if (bookId != null) {
      final viewer = ref.read(viewerProvider);
      _check(bookId, viewer.currentPage, viewer.mode, viewer.pageCount);
    }
    return state;
  }

  /// Which pages are in view and so should carry a scan prompt. In
  /// [ViewMode.doublePage] the visible spread is the pair whose left half is
  /// the odd page (1-indexed) <= currentPage; restore / jump may land on the
  /// right (even) half, so normalize to the left before checking, otherwise
  /// the left half (on screen) is never checked and the next (off-screen)
  /// page is checked instead (regression). The upper page is bounds-checked
  /// against [pageCount] so the last spread doesn't seed a phantom state.
  void _check(int bookId, int page1, ViewMode mode, int pageCount) {
    int left1 = page1;
    if (mode == ViewMode.doublePage && left1.isEven) {
      left1 = left1 - 1; // even page = right half -> its left sibling
    }
    // 0-indexed pages of the spread: {left1 - 1, left1}.
    for (final p0 in {left1 - 1, left1}) {
      if (p0 < 0 || p0 >= pageCount) continue;
      _checkPage(bookId, p0);
    }
  }

  /// Detect one page (0-indexed). Pages with an established state are left
  /// untouched: prompts survive page flips until acted on (7.1.2). A page
  /// with a cached OCR result (scanned in an earlier session, 7.1.4) is
  /// marked success directly -- the prompt must not nag again after a
  /// restart. The state read happens after the await so it never runs
  /// mid-build. Both the per-page null check and a bookId check guard the
  /// continuation: if the reader switched books mid-await, `build()` resets
  /// `pages` and changes `state.bookId`, so a stale result from book A must
  /// not be written into book B's state.
  Future<void> _checkPage(int bookId, int page0) async {
    try {
      final hasText = await _repo.pageHasText(bookId, page0);
      if (state.bookId != bookId) return; // switched books while awaiting
      if (state.of(page0) != null) return; // already established
      if (!hasText) {
        final cached = await cachedOcrAnyMode(
          repo: _repo,
          modeResolver: () =>
              configuredOcrMode(ref.read(aiConfigProvider.future)),
          bookId: bookId,
          page: page0,
        );
        if (state.bookId != bookId) return; // switched books while awaiting
        if (state.of(page0) != null) return;
        if (cached != null) {
          _set(page0, PageScanState(
            phase: ScanPhase.success,
            lowConfidence: cached.lines
                .where((l) => l.confidence < kLowConfidenceThreshold)
                .length,
          ));
          return;
        }
      }
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
    final bookId = state.bookId; // capture before awaits
    _set(page0, const PageScanState(phase: ScanPhase.scanning));
    try {
      final mode = await configuredOcrMode(ref.read(aiConfigProvider.future));
      final res = await _repo.scanPage(bookId, page0, mode);
      if (state.bookId != bookId) return; // switched books while scanning
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
            .where((l) => l.confidence < kLowConfidenceThreshold)
            .length,
      ));
    } catch (e) {
      if (state.bookId != bookId) return; // switched books while scanning
      _set(page0, PageScanState(phase: ScanPhase.error, error: e.toString()));
    }
  }

  /// Hide the prompt for [page0].
  void dismiss(int page0) {
    final p = state.of(page0);
    if (p == null) return;
    _set(page0, p.copyWith(phase: ScanPhase.dismissed));
  }

  /// Refresh the low-confidence count of [page0] after a manual correction
  /// (7.1.7): the scan overlay's "N 行置信度较低" hint must reflect the
  /// edited result, not the original scan.
  void refreshLowConfidence(int page0, int count) {
    final p = state.of(page0);
    if (p == null) return;
    _set(page0, p.copyWith(lowConfidence: count));
  }
}

/// Full-page scan state, per page of the open book.
final scanStateProvider = NotifierProvider<ScanNotifier, ScanState>(
  ScanNotifier.new,
);
