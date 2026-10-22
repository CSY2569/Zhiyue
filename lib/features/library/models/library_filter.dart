/// Which primary library view is active (FEATURES 2.7).
///
/// The rail entries are **mutually exclusive**: clicking 最近 shows every
/// recently opened book, clicking 收藏 shows every favorite, clicking a
/// folder shows that folder's books. File *types* (PDF / 图片) are a separate
/// axis owned by the shelf's top filter bar, so they combine with any view:
/// 「我的收藏 + PDF」 shows the favorite PDFs. Search stacks on top of both.
enum LibraryView { all, recent, favorite, category }

/// The file-type filter of the shelf's top bar. [all] means "every type".
///
/// Kept independent of [LibraryView] so the top bar and the rail never
/// duplicate each other (they used to offer the same five options, and
/// picking one highlighted the other control's entry too).
enum LibraryType { all, pdf, image }

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

  /// The active file-type filter.
  final LibraryType type;

  const LibraryFilter({
    this.searchQuery = '',
    this.view = LibraryView.all,
    this.categoryId,
    this.type = LibraryType.all,
  });

  /// Only [searchQuery] is ever copied here (the view / category / type are
  /// replaced wholesale by their own mutually-exclusive setters).
  LibraryFilter copyWith({String? searchQuery}) {
    return LibraryFilter(
      searchQuery: searchQuery ?? this.searchQuery,
      view: view,
      categoryId: categoryId,
      type: type,
    );
  }

  /// Whether this filter would match every book (no view filter, no type
  /// filter and no search); the search field has its own inline clear.
  bool get isClear =>
      searchQuery.isEmpty && view == LibraryView.all && type == LibraryType.all;
}
