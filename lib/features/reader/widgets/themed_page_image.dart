import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

/// A rendered page bitmap tinted for the active reading theme (FEATURES
/// 8.11). Light themes multiply a paper tint onto the page (white areas take
/// the tint, ink stays dark); the night theme applies an invert +
/// hue-rotate matrix so ink turns light while illustrations keep their hues.
///
/// The tint is applied to the bitmap only: selection / highlight /
/// annotation layers are siblings painted on top, keeping their colors true.
///
/// Light themes tint through [RawImage.color] + [BlendMode.multiply] instead
/// of a [ColorFiltered] layer. With one `ColorFiltered` per page, a spread
/// (double-page / double-scroll, two bitmaps side by side) lost the first
/// page: each `ColorFilterLayer` only rendered the tint colour for every
/// sibling except the last, so the left page came out blank and the spread
/// looked shifted. Painting the tint into the image paint itself renders both
/// pages correctly -- and avoids the `saveLayer` a colour-filter layer needs,
/// so selection drags have less to repaint.
class ThemedPageImage extends StatelessWidget {
  const ThemedPageImage({
    super.key,
    required this.image,
    this.fit = BoxFit.fill,
    this.filterQuality = FilterQuality.medium,
  });

  final ui.Image image;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final palette =
        Theme.of(context).extension<ReadingPalette>() ?? ReadingPalette.paper;
    final tint = palette.pageTint;
    final bitmap = RawImage(
      image: image,
      fit: fit,
      filterQuality: filterQuality,
      // `null` on the night palette (the matrix below does the work).
      color: tint,
      colorBlendMode: tint == null ? BlendMode.srcOver : BlendMode.multiply,
    );
    final matrix = palette.nightMatrix;
    if (matrix == null) return bitmap;
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(matrix),
      child: bitmap,
    );
  }
}
