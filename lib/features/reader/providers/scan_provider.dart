import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/api.dart' show OcrMode;

/// Scan state machine (FEATURES 7.1.2): a page without a text layer shows
/// the "扫描识别" prompt; scanning runs the engine and lands in success /
/// empty / error. The engine is a stub until the models are installed
/// (scripts/download_ocr_models.sh), so scanning currently surfaces the
/// "模型未安装" error -- the chain is fully wired.
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

class ScanState {
  const ScanState({
    required this.phase,
    required this.bookId,
    required this.page, // 1-indexed (viewer space)
    this.error,
  });

  final ScanPhase phase;
  final int bookId;
  final int page;
  final String? error;

  ScanState copyWith({
    ScanPhase? phase,
    int? bookId,
    int? page,
    String? error,
    bool clearError = false,
  }) {
    return ScanState(
      phase: phase ?? this.phase,
      bookId: bookId ?? this.bookId,
      page: page ?? this.page,
      error: clearError ? null : (error ?? this.error),
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
  /// -> cache. On success the char-box cache is invalidated so the OCR text
  /// layer becomes selectable (7.1.3).
  Future<void> scan() async {
    if (state.phase == ScanPhase.scanning) return;
    state = state.copyWith(phase: ScanPhase.scanning, clearError: true);
    try {
      final res =
          await _repo.scanPage(state.bookId, state.page - 1, OcrMode.highPrecision);
      if (res.error != null) {
        state = state.copyWith(phase: ScanPhase.error, error: res.error);
        return;
      }
      ref.invalidate(charBoxCacheProvider);
      state = state.copyWith(
        phase: res.lines.isEmpty ? ScanPhase.empty : ScanPhase.success,
      );
    } catch (e) {
      state = state.copyWith(phase: ScanPhase.error, error: e.toString());
    }
  }

  /// Hide the prompt for the current page.
  void dismiss() => state = state.copyWith(phase: ScanPhase.dismissed);
}

/// Full-page scan state for the open book (auto-resets on page flips).
final scanStateProvider = NotifierProvider<ScanNotifier, ScanState>(
  ScanNotifier.new,
);
