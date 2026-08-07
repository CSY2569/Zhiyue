import 'package:rbwa/src/rust/models/annotation.dart' show NormRect;

/// A character-range selection on one page (FEATURES 4.1).
///
/// Selection is a *range* over the page's CharBox list:
/// - [anchorIndex] is where the drag started; [currentIndex] is the current
///   pointer position. Dragging "backwards" (current < anchor) selects in
///   reverse -- the derived [text] / [lineRects] always cover the inclusive
///   range between them (FEATURES 4.1.1).
/// - [lineRects] holds one *normalized* rect per selected line, computed by
///   row clustering; these are the rects stored for highlight/underline/
///   strikethrough annotations (FEATURES 4.3.1/4.3.2).
class Selection {
  const Selection({
    required this.page, // 0-indexed
    required this.anchorIndex,
    required this.currentIndex,
    required this.text,
    required this.lineRects,
  });

  final int page;
  final int anchorIndex;
  final int currentIndex;
  final String text;
  final List<NormRect> lineRects;
}
