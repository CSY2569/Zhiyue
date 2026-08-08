import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/library_repository.dart';
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/src/rust/models/book.dart';
import 'package:rbwa/src/rust/models/progress.dart';

/// Which sidebar panel is open (FEATURES 3.4.4). The annotations panel
/// lists both text-layer marks and image-layer marks (FEATURES 4.5.1 / 5.5).
enum SidebarType { thumbnails, outline, annotations }

/// Immutable snapshot of the reader's state (FEATURES §3).
class ViewerState {
  final Book? book;
  final int pageCount;
  final int currentPage; // 1-indexed for display; 0-indexed internally
  final double zoom; // 0.3–4.0, default 1.2
  final ViewMode mode;
  final bool loading;
  final String? error;
  final SidebarType? openSidebar;

  const ViewerState({
    this.book,
    this.pageCount = 0,
    this.currentPage = 1,
    this.zoom = 1.2,
    this.mode = ViewMode.single,
    this.loading = true,
    this.error,
    this.openSidebar,
  });

  ViewerState copyWith({
    Book? book,
    int? pageCount,
    int? currentPage,
    double? zoom,
    ViewMode? mode,
    bool? loading,
    String? error,
    SidebarType? openSidebar,
    bool clearSidebar = false,
  }) {
    return ViewerState(
      book: book ?? this.book,
      pageCount: pageCount ?? this.pageCount,
      currentPage: currentPage ?? this.currentPage,
      zoom: zoom ?? this.zoom,
      mode: mode ?? this.mode,
      loading: loading ?? this.loading,
      error: error ?? this.error,
      openSidebar: clearSidebar ? null : (openSidebar ?? this.openSidebar),
    );
  }
}

/// Manages the reader's state: book loading, page navigation, zoom, view mode,
/// sidebar toggling, and debounced progress persistence (FEATURES 3.1-3.4).
class ViewerNotifier extends StateNotifier<ViewerState> {
  ViewerNotifier(this._ref) : super(const ViewerState());

  final Ref _ref;
  Timer? _saveDebounce;

  ReaderRepository get _readerRepo => _ref.read(readerRepositoryProvider);
  LibraryRepository get _libraryRepo => _ref.read(libraryRepositoryProvider);

  /// Load the book, open its PDF, and restore saved progress (FEATURES 3.3.4).
  Future<void> openBook(int bookId) async {
    state = const ViewerState().copyWith(loading: true);
    try {
      final book = await _libraryRepo.getBook(bookId);
      if (book == null) {
        state = const ViewerState().copyWith(
          loading: false,
          error: '书籍不存在',
        );
        return;
      }

      // Both PDFs and image books go through Rust open_book: it routes by
      // the stored book's type (pdfium vs image crate) and switches the
      // render pipeline. Skipping it for images left the previous PDF open,
      // so an image book rendered that PDF's first page (regression).
      final result = await _readerRepo.openBook(book.storedPath);
      if (result.error != null) {
        state = ViewerState(
          book: book,
          loading: false,
          error: result.error,
        );
        return;
      }
      final pageCount = result.pageCount;

      // Restore saved progress.
      final progress = await _readerRepo.getProgress(bookId);
      state = ViewerState(
        book: book,
        pageCount: pageCount,
        currentPage: progress?.page ?? 1,
        zoom: progress?.zoom ?? 1.2,
        mode: progress?.viewMode ?? ViewMode.single,
        loading: false,
      );
    } catch (e) {
      state = const ViewerState().copyWith(
        loading: false,
        error: '打开书籍失败: $e',
      );
    }
  }

  void setZoom(double z) {
    final clamped = z.clamp(0.3, 4.0);
    state = state.copyWith(zoom: clamped);
    _scheduleSave();
  }

  void zoomIn() => setZoom(state.zoom + 0.1);
  void zoomOut() => setZoom(state.zoom - 0.1);
  void resetZoom() => setZoom(1.2);

  void setPage(int page) {
    final clamped = page.clamp(1, state.pageCount);
    state = state.copyWith(currentPage: clamped);
    _scheduleSave();
  }

  void nextPage() {
    final step = state.mode == ViewMode.doublePage ? 2 : 1;
    setPage(state.currentPage + step);
  }

  void prevPage() {
    final step = state.mode == ViewMode.doublePage ? 2 : 1;
    setPage(state.currentPage - step);
  }

  void setMode(ViewMode mode) {
    state = state.copyWith(mode: mode);
    _scheduleSave();
  }

  void toggleSidebar(SidebarType type) {
    if (state.openSidebar == type) {
      state = state.copyWith(clearSidebar: true);
    } else {
      state = state.copyWith(openSidebar: type);
    }
  }

  /// Debounced progress persistence (FEATURES 3.3.4: 800ms).
  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 800), _saveProgress);
  }

  Future<void> _saveProgress() async {
    if (state.book == null) return;
    try {
      await _readerRepo.saveProgress(
        state.book!.id,
        state.currentPage,
        state.zoom,
        _viewModeString(state.mode),
      );
    } catch (_) {}
  }

  String _viewModeString(ViewMode m) {
    switch (m) {
      case ViewMode.single:
        return 'single';
      case ViewMode.doubleScroll:
        return 'double_scroll';
      case ViewMode.doublePage:
        return 'double_page';
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}

/// Provider for the reader's state. Created per-book (family) so navigating
/// between books gets a fresh state.
final viewerProvider =
    StateNotifierProvider<ViewerNotifier, ViewerState>((ref) {
  return ViewerNotifier(ref);
});
