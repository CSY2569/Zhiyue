import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/char_box_cache.dart';
import 'package:rbwa/features/annotation/selection_geometry.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;
import 'package:rbwa/src/rust/pdf/types.dart' show CharBox;

/// In-page hit-word highlight for full-text search (M6, 3.5.3): when the
/// [searchHitProvider] targets this page, every occurrence of the query is
/// located in the char-box text (exactly aligned with the boxes) and painted
/// as translucent rects. OCR pages highlight at line level -- their
/// invisible text layer is one box per recognized line.
///
/// Rendered as part of the page Stack, below the selection layer, and
/// wrapped in [IgnorePointer] so it never intercepts gestures.
class HitHighlightLayer extends ConsumerWidget {
  const HitHighlightLayer({
    super.key,
    required this.bookId,
    required this.page,
  });

  final int bookId;
  final int page; // 0-indexed

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = ref.watch(searchHitProvider);
    if (target == null ||
        target.bookId != bookId ||
        target.page != page) {
      return const SizedBox.shrink();
    }
    // Preload the char boxes (the selection layer would fetch them anyway;
    // here we need them to compute the highlight rects).
    final boxes = ref.watch(charBoxCacheProvider.select((m) => m[page]));
    if (boxes == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(charBoxCacheProvider.notifier).getOrFetch(bookId, page);
      });
      return const SizedBox.shrink();
    }
    final rects = hitRects(boxes, target.query);
    if (rects.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _HitHighlightPainter(rects),
      ),
    );
  }
}

/// Normalized rects of every occurrence of [query] in the page's box text
/// (case-insensitive; each occurrence is one or more line rects via
/// [selectionRects]).
List<NormRect> hitRects(List<CharBox> boxes, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty || boxes.isEmpty) return const [];
  final text = boxes.map((b) => b.char).join().toLowerCase();
  final out = <NormRect>[];
  var from = 0;
  while (true) {
    final idx = text.indexOf(q, from);
    if (idx < 0) break;
    out.addAll(selectionRects(boxes, idx, idx + q.length - 1));
    from = idx + q.length;
  }
  return out;
}

class _HitHighlightPainter extends CustomPainter {
  _HitHighlightPainter(this.rects);

  final List<NormRect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x59FFC107) // translucent amber
      ..style = PaintingStyle.fill;
    for (final r in rects) {
      canvas.drawRect(
        Rect.fromLTWH(
          r.x * size.width,
          r.y * size.height,
          r.w * size.width,
          r.h * size.height,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_HitHighlightPainter oldDelegate) =>
      oldDelegate.rects != rects;
}
