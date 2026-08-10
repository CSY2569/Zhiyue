import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/ai/providers/ai_config_provider.dart';
import 'package:rbwa/features/reader/providers/ocr_helpers.dart';
import 'package:rbwa/features/reader/providers/scan_provider.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine;

/// A low-confidence OCR line: [index] is its position in the page's cached
/// OcrResult lines (needed by the 7.1.7 edit API), [line] the line itself
/// (text + normalized rect + confidence).
typedef LowConfidenceLine = ({int index, OcrLine line});

/// LRU cache of per-page low-confidence OCR lines (FEATURES 7.1.6). Shared by
/// the marking layer (paints the markers) and the selection layer (tap a
/// marker to edit the line, 7.1.7), so both see the same data without
/// fetching the OCR result twice.
class LowConfidenceCache extends Notifier<Map<int, List<LowConfidenceLine>>> {
  static const int _maxPages = 8;

  @override
  Map<int, List<LowConfidenceLine>> build() {
    // Switching books invalidates cached page data.
    ref.listen(viewerProvider.select((s) => s.book?.id), (prev, next) {
      if (prev != next) state = {};
    });
    // A finished scan changes the OCR result of that page: drop its cache.
    ref.listen(scanStateProvider, (prev, next) {
      if (prev == next) return;
      for (final entry in next.pages.entries) {
        if (entry.value.phase == ScanPhase.success ||
            entry.value.phase == ScanPhase.empty) {
          if (state.containsKey(entry.key)) {
            final nextMap = Map<int, List<LowConfidenceLine>>.from(state)
              ..remove(entry.key);
            state = nextMap;
          }
        }
      }
    });
    return {};
  }

  /// Low-confidence lines for [page], fetching the OCR result on first
  /// access (lines below [kLowConfidenceThreshold], with their indices).
  Future<List<LowConfidenceLine>> getOrFetch(int bookId, int page) async {
    final hit = state[page];
    if (hit != null) return hit;

    List<LowConfidenceLine> lines;
    try {
      final ocr = await cachedOcrAnyMode(
        repo: ref.read(readerRepositoryProvider),
        modeResolver: () => configuredOcrMode(ref.read(aiConfigProvider.future)),
        bookId: bookId,
        page: page,
      );
      lines = [
        for (var i = 0; i < (ocr?.lines.length ?? 0); i++)
          if (ocr!.lines[i].confidence < kLowConfidenceThreshold)
            (index: i, line: ocr.lines[i]),
      ];
    } catch (_) {
      lines = const [];
    }

    // Re-insert at the tail to keep insertion order = LRU order.
    final next = Map<int, List<LowConfidenceLine>>.from(state)
      ..remove(page)
      ..[page] = lines;
    while (next.length > _maxPages) {
      next.remove(next.keys.first);
    }
    state = next;
    return lines;
  }
}

/// Low-confidence OCR lines of the open book (auto-clears on book switch).
final lowConfidenceCacheProvider =
    NotifierProvider<LowConfidenceCache, Map<int, List<LowConfidenceLine>>>(
  LowConfidenceCache.new,
);
