import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/annotation/providers/low_confidence_provider.dart';
import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/src/rust/ocr.dart' show OcrLine;

/// Low-confidence OCR line marking (FEATURES 7.1.6): draws a translucent
/// amber marker over every recognized line whose confidence is below
/// [kLowConfidenceThreshold], so the reader can spot at a glance which lines
/// are worth double-checking against the original page. Tap a marker to edit
/// the line text (7.1.7) -- the tap handling lives in [SelectionLayer] via
/// the shared [lowConfidenceCacheProvider].
///
/// Only renders for OCR (line-level) boxes -- native PDF pages have a real
/// text layer and no confidence data. The layer is pointer-transparent
/// (IgnorePointer) so it never intercepts selection / annotation gestures.
class LowConfidenceLayer extends ConsumerWidget {
  const LowConfidenceLayer({
    super.key,
    required this.bookId,
    required this.page,
  });

  final int bookId;
  final int page; // 0-indexed

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final boxes = ref.watch(charBoxCacheProvider.select((m) => m[page]));
    if (boxes == null) {
      // Preload the char boxes; the low-confidence cache is fetched
      // alongside (the selection layer reads it on tap).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(charBoxCacheProvider.notifier).getOrFetch(bookId, page);
        ref
            .read(lowConfidenceCacheProvider.notifier)
            .getOrFetch(bookId, page);
      });
      return const SizedBox.shrink();
    }
    if (!isLineLevelBoxes(boxes)) {
      return const SizedBox.shrink(); // native PDF: no confidence data
    }
    final low = ref.watch(
      lowConfidenceCacheProvider.select((m) => m[page] ?? const []),
    );
    if (low.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _LowConfidencePainter(low.map((e) => e.line).toList()),
      ),
    );
  }
}

/// Paints translucent amber markers over each low-confidence line box.
class _LowConfidencePainter extends CustomPainter {
  _LowConfidencePainter(this.lines);

  final List<OcrLine> lines;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final fill = Paint()
      ..color = const Color(0x33FFC107) // translucent amber fill
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = const Color(0x66FF9800) // translucent orange border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final l in lines) {
      final rect = Rect.fromLTWH(
        l.x * size.width,
        l.y * size.height,
        l.w * size.width,
        l.h * size.height,
      );
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, stroke);
    }
  }

  @override
  bool shouldRepaint(_LowConfidencePainter oldDelegate) =>
      oldDelegate.lines != lines;
}
