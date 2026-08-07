/// Which primary library view is active (FEATURES 2.7).
///
/// The rail entries are **mutually exclusive**: clicking PDF shows every PDF,
/// clicking 图片 shows every image, clicking 收藏 shows every favorite,
/// clicking a category shows that category's books -- one active view at a
/// time, so the components never interfere. Search is the only filter that
/// stacks on top of the active view.
enum LibraryView { all, pdf, image, favorite, category }

/// Immutable filter state for the library view (FEATURES 2.7).
///
/// Kept intentionally simple (no freezed) to avoid a build_runner dependency
/// for a single value object.
class LibraryFilter {
  /// Case-insensitive substring matched against the book title.
  final String searchQuery;

  /// The active primary view (exactly one at a time).
  final LibraryView view;

  /// The selected category; only meaningful when [view] is
  /// [LibraryView.category].
  final int? categoryId;

  const LibraryFilter({
    this.searchQuery = '',
    this.view = LibraryView.all,
    this.categoryId,
  });

  /// Only [searchQuery] is ever copied (the view / category are replaced
  /// wholesale by the rail's mutually-exclusive setters).
  LibraryFilter copyWith({String? searchQuery}) {
    return LibraryFilter(
      searchQuery: searchQuery ?? this.searchQuery,
      view: view,
      categoryId: categoryId,
    );
  }

  /// Whether this filter would match every book (no view filter and no
  /// search); the search field has its own inline clear.
  bool get isClear => searchQuery.isEmpty && view == LibraryView.all;
}
