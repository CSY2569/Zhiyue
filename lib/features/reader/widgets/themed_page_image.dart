import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

/// A rendered page bitmap tinted for the active reading theme (FEATURES
/// 8.11). Light themes multiply a paper tint onto the page (white areas take
/// the tint, ink stays dark); the night theme applies an invert +
/// hue-rotate matrix so ink turns light while illustrations keep their hues.
///
/// The [ColorFiltered] wraps ONLY the bitmap: selection / highlight /
/// annotation layers are siblings painted on top, keeping their colors true.
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
    return ColorFiltered(
      colorFilter: palette.pageColorFilter,
      child: RawImage(
        image: image,
        fit: fit,
        filterQuality: filterQuality,
      ),
    );
  }
}
