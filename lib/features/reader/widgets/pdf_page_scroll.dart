import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/widgets/highlight_layer.dart';
import 'package:rbwa/features/annotation/widgets/image_mark_layer.dart';
import 'package:rbwa/features/annotation/widgets/low_confidence_layer.dart';
import 'package:rbwa/features/annotation/widgets/selection_layer.dart';
import 'package:rbwa/features/reader/providers/bitmap_cache.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/widgets/hit_highlight_layer.dart';
import 'package:rbwa/features/reader/widgets/scan_overlay.dart';
import 'package:rbwa/features/reader/widgets/themed_page_image.dart';
import 'package:rbwa/src/rust/models/annotation.dart' show TextAnnotation;
import 'package:rbwa/src/rust/models/progress.dart';
import 'package:rbwa/platform/platform_host.dart';

/// Virtual-scrolling container that displays PDF pages in one of three view
/// modes (FEATURES 3.1 / 3.6).
///
/// Layout model (like mainstream PDF readers):
/// - Pages are displayed at their *physical size × zoom* -- no width clamping
///   ("不要给文档内层设置大小限制").
/// - Content is always centered in the viewport. Because the center stays
///   fixed, zooming naturally grows/shrinks the pages around the viewport
///   center (scale-from-center).
/// - When content is wider than the viewport, double-scroll rows scroll
///   horizontally, center-anchored; single pages clip their overflow.
///
/// Modes:
/// - [ViewMode.single]: `ListView.builder`, one page per item, vertical scroll.
/// - [ViewMode.doubleScroll]: `ListView.builder`, each row is two pages side
///   by side (16px gutter), horizontally scrollable and center-anchored.
/// - [ViewMode.doublePage]: `PageView.builder`, step 2, left page aligned to
///   odd index; wheel scroll flips pages (throttled 250ms).
class PdfPageScroll extends ConsumerStatefulWidget {
  const PdfPageScroll({super.key});

  @override
  ConsumerState<PdfPageScroll> createState() => _PdfPageScrollState();
}

class _PdfPageScrollState extends ConsumerState<PdfPageScroll> {
  final _scrollController = ScrollController();
  // True while we are programmatically scrolling (from a jump request), so
  // the offset listener does not re-report the page and fight the caller.
  bool _fromScroll = false;
  // Whether the scroll offset has been aligned to the current page height.
  // The SliverList keeps the measured geometry of laid-out items, so a
  // second alignment with a different height (pages are not all the same
  // physical size -- e.g. a cover page) would misplace the offset by many
  // pages. Align once per book/zoom; page flips align naturally via scroll.
  bool _aligned = false;
  // The page's physical height (pt) locked at alignment time. The item
  // stride is `physicalH × zoom + gap`, computed with the *current* zoom so
  // within-tier nudges stay exact (the SliverList re-lays out items at the
  // new display height, and the scroll math tracks it).
  double? _alignedPhysicalH;
  // Most recent page requested while a programmatic scroll animation was
  // running; the animation's completion jumps to it instead of stranding the
  // list on the previous page.
  int? _pendingPageJump;
  late final ProviderSubscription _pageSub;
  late final ProviderSubscription _pageHeightSub;
  late final ProviderSubscription _realignSub;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // External page changes (toolbar / page-jump / outline / thumbnails)
    // drive the scroll position in single & double-scroll modes.
    // Double-page-flip mode handles this inside its own PageView.
    _pageSub = ref.listenManual(
      viewerProvider.select((s) => s.currentPage),
      (prev, next) {
        if (!_scrollController.hasClients) return;
        if (ref.read(viewerProvider).mode == ViewMode.doublePage) return;
        // A page change arriving while the previous animation runs (rapid
        // next/prev taps, volume-key flips) must RE-TARGET the scroll, not
        // be dropped: dropping it left the list on page 2 while the state
        // said page 3, until the next manual scroll.
        _pendingPageJump = next;
        if (_fromScroll) return;
        _animateToPage(next);
      },
    );
    // When the page height becomes known (first page rendered) or changes
    // (zoom crossing a render tier), re-align the scroll position to the
    // current page so the reported page matches what is on screen.
    _pageHeightSub = ref.listenManual(pageHeightProvider, (prev, next) {
      if (prev == next) return;
      if (!_scrollController.hasClients) return;
      if (ref.read(viewerProvider).mode == ViewMode.doublePage) return;
      // Align exactly once per book/zoom-tier, locking the physical height:
      // the SliverList never re-measures already-laid-out items, so a second
      // jump with a different height (PDFs with unequal page sizes, e.g. a
      // shorter cover) would land many pages off -- and the restored page
      // would never get its scan prompt (regression). Page flips align via
      // the scroll listener. Within-tier zoom nudges don't trigger this (the
      // physical height is constant), so the stride stays valid and the
      // scroll math tracks the new display height via `_currentStride`.
      if (_aligned) return;
      _aligned = true;
      _alignedPhysicalH = next;
      // Rebuild so the placeholder height switches to the locked stride
      // (the SliverList geometry must match the scroll math below).
      if (mounted) setState(() {});
      _fromScroll = true;
      final zoom = ref.read(viewerProvider).zoom;
      final target = _offsetForPage(
              ref.read(viewerProvider).currentPage, next * zoom)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(target);
      _fromScroll = false;
    });
    // A new book, zoom change, or view-mode switch requires re-aligning the
    // scroll offset.
    // - Book switch: clear the locked height; the first page of the new book
    //   reports its height and the `_pageHeightSub` realigns.
    // - Zoom change: the display height (physical × zoom) changes even when
    //   the physical height is constant (within-tier nudge), so re-jump to
    //   the current page using the already-known physical height. If no
    //   height is known yet (first render pending), clear and wait for the
    //   report. Keeping `_alignedPhysicalH` lets `_currentStride` track the
    //   new zoom immediately instead of going stale.
    // - Mode switch: the old ListView/PageView is unmounted and a fresh one
    //   starts at offset 0, so re-jump to the current page on the next frame
    //   (the new scroll position isn't attached yet at callback time).
    //   doublePage is handled by `_DoublePageFlip.initState` (it seeds its
    //   PageController from currentPage), so only single/doubleScroll need
    //   the re-jump.
    _realignSub = ref.listenManual(
      viewerProvider.select((s) => (s.book?.id, s.zoom, s.mode)),
      (prev, next) {
        if (prev == next) return;
        final bookChanged = prev?.$1 != next.$1;
        final modeChanged = prev?.$3 != next.$3;
        if (bookChanged) {
          _aligned = false;
          _alignedPhysicalH = null;
          // The next book's page size is unknown until its first bitmap
          // lands; keeping the previous book's width would size the new
          // placeholders wrong (visible as a sideways jump in the double
          // modes when the new pages are not the same size). This listener
          // runs outside build, so touching a provider is safe.
          ref.read(pageWidthProvider.notifier).state = null;
          if (mounted) setState(() {});
          return;
        }
        if (modeChanged) {
          // doublePage seeds its own PageController in initState; nothing to
          // do here. single/doubleScroll need a re-jump once the new
          // ListView attaches its scroll position (next frame).
          if (next.$3 == ViewMode.doublePage) return;
          if (!mounted) return;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scrollController.hasClients) return;
            final viewer = ref.read(viewerProvider);
            if (viewer.mode == ViewMode.doublePage) return;
            final double physicalH =
                _alignedPhysicalH ?? ref.read(pageHeightProvider);
            if (physicalH <= 0) return;
            _fromScroll = true;
            final target = _offsetForPage(
                    viewer.currentPage, physicalH * viewer.zoom)
                .clamp(0.0, _scrollController.position.maxScrollExtent);
            _scrollController.jumpTo(target);
            _fromScroll = false;
          });
          return;
        }
        // Zoom changed. Re-jump using the known physical height so the page
        // shown matches the reported page after the display height changes.
        final physicalH = _alignedPhysicalH;
        if (physicalH == null || !_scrollController.hasClients) {
          _aligned = false;
          if (mounted) setState(() {});
          return;
        }
        if (ref.read(viewerProvider).mode == ViewMode.doublePage) return;
        if (mounted) setState(() {}); // placeholder height tracks new zoom
        _fromScroll = true;
        final target = _offsetForPage(
                ref.read(viewerProvider).currentPage, physicalH * next.$2)
            .clamp(0.0, _scrollController.position.maxScrollExtent);
        _scrollController.jumpTo(target);
        _fromScroll = false;
      },
    );
  }

  /// The item stride (page display height + gap) used by the scroll math:
  /// the locked physical height × current zoom + gap, else the last reported
  /// physical height × current zoom + gap. Using the current zoom keeps the
  /// stride in sync with within-tier zoom nudges (the SliverList re-lays out
  /// items at the new display height).
  double _currentStride() {
    final zoom = ref.read(viewerProvider).zoom;
    final double physicalH =
        _alignedPhysicalH ?? ref.read(pageHeightProvider);
    return _pageStride(physicalH * zoom);
  }

  /// Scroll offset (in the vertical list) at which page [page] (1-indexed)
  /// sits, given one page's display height [pageH]. Accounts for the vertical
  /// gap between items.
  double _offsetForPage(int page, double pageH) {
    final stride = _pageStride(pageH);
    if (ref.read(viewerProvider).mode == ViewMode.doubleScroll) {
      // Each row holds two pages; row height ≈ one page height + gap.
      return ((page - 1) ~/ 2) * stride;
    }
    return (page - 1) * stride;
  }

  /// Animates to [page] and, if another page was requested meanwhile, keeps
  /// going to the latest one instead of stopping at the stale target.
  void _animateToPage(int page) {
    if (!_scrollController.hasClients) return;
    final viewer = ref.read(viewerProvider);
    // [_offsetForPage] takes one page's DISPLAY height and adds the gap
    // itself. Passing the stride (height + gap) here added the gap a second
    // time, so every flip landed 16dp past the page -- the reader drifted
    // further off with each page turn (desktop double-scroll / double-page
    // looked misaligned after a few flips).
    final double physicalH =
        _alignedPhysicalH ?? ref.read(pageHeightProvider);
    final target = _offsetForPage(page, physicalH * viewer.zoom)
        .clamp(0.0, _scrollController.position.maxScrollExtent);
    _fromScroll = true;
    _scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          _fromScroll = false;
          final pending = _pendingPageJump;
          _pendingPageJump = null;
          if (pending != null && pending != page) {
            _animateToPage(pending);
          }
        });
  }

  @override
  void dispose() {
    _realignSub.close();
    _pageHeightSub.close();
    _pageSub.close();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// Tracks the current page from the scroll offset using the *measured* page
  /// height (reported by the first rendered page via `onPageHeightKnown`).
  /// All pages of a PDF share the same height, so this division is exact --
  /// no estimation, hence no desync even after fast scrolling.
  void _onScroll() {
    if (_fromScroll) return;
    final state = ref.read(viewerProvider);
    if (state.pageCount == 0 || !_scrollController.hasClients) return;

    final viewport = _scrollController.position.viewportDimension;
    if (viewport == 0) return;
    final offset = _scrollController.offset;
    final stride = _currentStride();
    if (stride <= 0) return;

    int page;
    if (state.mode == ViewMode.doubleScroll) {
      // Each row holds two pages; row height ≈ one page height + gap.
      final row = (offset + stride / 2) ~/ stride;
      page = row * 2 + 1;
    } else {
      page = (offset + stride / 2) ~/ stride + 1;
    }
    final clamped = page.clamp(1, state.pageCount);
    if (clamped != state.currentPage) {
      _fromScroll = true;
      ref.read(viewerProvider.notifier).setPage(clamped);
      _fromScroll = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(viewerProvider);
    final devicePixelRatio = effectiveRenderDpi(
      MediaQuery.devicePixelRatioOf(context),
      state.zoom,
    );

    if (state.pageCount == 0) {
      return const Center(child: Text('无页面'));
    }

    // The placeholder height/width of not-yet-loaded pages: the locked
    // alignment height once known (so the SliverList geometry matches the
    // scroll math), else the last reported page size. The width matters most
    // in the double modes: a zero-width placeholder makes a row collapse to
    // just its gutter, and the row is then re-centred when the bitmaps
    // arrive -- the visible "double-scroll jumps sideways" defect.
    final placeholderPageH = _currentStride() - kPageGap;
    final placeholderPageW =
        (ref.read(pageWidthProvider) ?? 0) * state.zoom;

    switch (state.mode) {
      case ViewMode.single:
        return _SingleScroll(
          scrollController: _scrollController,
          pageCount: state.pageCount,
          bookId: state.book?.id ?? 0,
          zoom: state.zoom,
          dpiScale: devicePixelRatio,
          placeholderHeight: placeholderPageH,
          placeholderWidth: placeholderPageW,
        );
      case ViewMode.doubleScroll:
        return _DoubleScroll(
          scrollController: _scrollController,
          pageCount: state.pageCount,
          bookId: state.book?.id ?? 0,
          zoom: state.zoom,
          dpiScale: devicePixelRatio,
          placeholderHeight: placeholderPageH,
          placeholderWidth: placeholderPageW,
        );
      case ViewMode.doublePage:
        return _DoublePageFlip(
          pageCount: state.pageCount,
          bookId: state.book?.id ?? 0,
          zoom: state.zoom,
          dpiScale: devicePixelRatio,
          placeholderHeight: placeholderPageH,
          placeholderWidth: placeholderPageW,
        );
    }
  }
}

/// Render DPI for the current zoom.
///
/// Phones report devicePixelRatio 2.75-3.5, which makes an A4 page ~26MB of
/// RGBA at the default 1.2x zoom -- only 3-4 pages fit the byte budget, so
/// flipping quickly always paid for a fresh render. While the page fits the
/// screen (browsing), 2.0x is already sharper than the eye resolves at reading
/// distance; once the reader zooms in for detail we switch back to the full
/// device DPR and the existing sharpen pass re-renders.
double effectiveRenderDpi(double deviceDpr, double zoom) {
  if (zoom <= 1.4) return deviceDpr.clamp(1.0, 2.0);
  return deviceDpr;
}

/// Gutter (horizontal gap) between the two pages of a double-mode row.
const double kGutter = 8;

/// Vertical gap between pages (single mode) / rows (double-scroll mode).
const double kPageGap = 16;

/// The stride (scroll extent) of one page item: page height + vertical gap.
/// Used by the scroll listener / jump logic so the page number stays exact
/// despite the gaps.
double _pageStride(double pageH) => pageH + kPageGap;

/// Physical height (pt, zoom-independent) of one page, reported by the first
/// rendered page (via an async callback -- never during build). The display
/// height is `physical × zoom`, computed where needed so within-tier zoom
/// nudges don't make the alignment stride stale.
final pageHeightProvider = StateProvider<double>((ref) => 800.0 / 1.2);

/// Physical width (pt, zoom-independent) of one page, reported next to
/// [pageHeightProvider]. Placeholders in the double modes need it: a page
/// placeholder without width collapses the spread row to its gutter until the
/// bitmap lands, and the row then jumps sideways when it is re-centred.
final pageWidthProvider = StateProvider<double?>((ref) => null);

/// Single-page continuous scroll (FEATURES 3.1.1).
///
/// Each page is centered in the viewport at its physical size × zoom; when
/// zoomed past the viewport width the overflow is clipped symmetrically, so
/// the page center stays fixed (scale-from-center).
class _SingleScroll extends ConsumerWidget {
  const _SingleScroll({
    required this.scrollController,
    required this.pageCount,
    required this.bookId,
    required this.zoom,
    required this.dpiScale,
    required this.placeholderHeight,
    required this.placeholderWidth,
  });

  final ScrollController scrollController;
  final int pageCount;
  final int bookId;
  final double zoom;
  final double dpiScale;
  final double placeholderHeight;
  final double placeholderWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.read(bitmapCacheProvider);
    // Use the measured page height as the placeholder height so items don't
    // jump in height before/after loading (which would desync the scroll
    // offset from the page number).
    final pageH = placeholderHeight;

    return ListView.builder(
      controller: scrollController,
      itemCount: pageCount,
      // Default cacheExtent (250px) is shorter than one phone page, so fast
      // scrolling outran the renderer and showed placeholders. Keep about one
      // page of look-ahead in each direction; bitmaps beyond it are dropped by
      // the cache's byte budget instead of accumulating.
      scrollCacheExtent: ScrollCacheExtent.pixels(pageH > 0 ? pageH : 800),
      itemBuilder: (context, index) {
        // NOTE: do NOT use OverflowBox here -- ListView items get an unbounded
        // height constraint, and OverflowBox(maxHeight: infinity) tries to
        // size itself to infinity, crashing layout. UnconstrainedBox lets the
        // page keep its true size (physical × zoom) and overflow centered.
        // `clipBehavior: Clip.hardEdge` clips that overflow right here instead
        // of drawing the debug zebra-stripe overflow indicator (UnconstrainedBox
        // defaults to Clip.none, which paints one whenever the zoomed page is
        // wider than the viewport); the outer ClipRect crops it symmetrically
        // anyway (scale-from-center).
        return Padding(
          padding: const EdgeInsets.only(bottom: kPageGap),
          child: ClipRect(
            child: Center(
              child: UnconstrainedBox(
                alignment: Alignment.center,
                clipBehavior: Clip.hardEdge,
                child: _PageItem(
                  cache: cache,
                  bookId: bookId,
                  page: index,
                  zoom: zoom,
                  dpiScale: dpiScale,
                  placeholderHeight: pageH,
                  placeholderWidth: placeholderWidth,
                  onPageHeightKnown: (h) =>
                      ref.read(pageHeightProvider.notifier).state = h,
                  onPageWidthKnown: (w) =>
                      ref.read(pageWidthProvider.notifier).state = w,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Double-page continuous scroll (FEATURES 3.1.2): each row is two pages side
/// by side with a gutter, displayed at physical size × zoom. The row is
/// centered when it fits the viewport; when wider, it scrolls horizontally,
/// center-anchored -- zooming grows the pages around the viewport center.
class _DoubleScroll extends ConsumerWidget {
  const _DoubleScroll({
    required this.scrollController,
    required this.pageCount,
    required this.bookId,
    required this.zoom,
    required this.dpiScale,
    required this.placeholderHeight,
    required this.placeholderWidth,
  });

  final ScrollController scrollController;
  final int pageCount;
  final int bookId;
  final double zoom;
  final double dpiScale;
  final double placeholderHeight;
  final double placeholderWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cache = ref.read(bitmapCacheProvider);
    final rowCount = (pageCount / 2).ceil();
    // Measured page height -> placeholder height (stable item layout).
    final pageH = placeholderHeight;

    return ListView.builder(
      controller: scrollController,
      itemCount: rowCount,
      scrollCacheExtent: ScrollCacheExtent.pixels(pageH > 0 ? pageH : 800),
      itemBuilder: (context, rowIndex) {
        final leftPage = rowIndex * 2;
        final rightPage = leftPage + 1;
        // Bottom padding creates the vertical gap between rows.
        return Padding(
          padding: const EdgeInsets.only(bottom: kPageGap),
          child: _RowScroll(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PageItem(
                  cache: cache,
                  bookId: bookId,
                  page: leftPage,
                  zoom: zoom,
                  dpiScale: dpiScale,
                  placeholderHeight: pageH,
                  placeholderWidth: placeholderWidth,
                  onPageHeightKnown: (h) =>
                      ref.read(pageHeightProvider.notifier).state = h,
                  onPageWidthKnown: (w) =>
                      ref.read(pageWidthProvider.notifier).state = w,
                ),
                const SizedBox(width: kGutter),
                if (rightPage < pageCount)
                  _PageItem(
                    cache: cache,
                    bookId: bookId,
                    page: rightPage,
                    zoom: zoom,
                    dpiScale: dpiScale,
                    placeholderHeight: pageH,
                    placeholderWidth: placeholderWidth,
                    onPageHeightKnown: (h) =>
                        ref.read(pageHeightProvider.notifier).state = h,
                    onPageWidthKnown: (w) =>
                        ref.read(pageWidthProvider.notifier).state = w,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A horizontally scrollable row whose content is always centered in the
/// viewport: when the content is narrower than the viewport it is centered
/// with no scrolling; when wider, the scroll position is anchored to the
/// center. On zoom change the row width changes and the position re-anchors,
/// so zooming grows/shrinks the pages around the viewport center.
class _RowScroll extends StatefulWidget {
  const _RowScroll({required this.child});

  final Widget child;

  @override
  State<_RowScroll> createState() => _RowScrollState();
}

class _RowScrollState extends State<_RowScroll> {
  late final ScrollController _controller;
  final _childKey = GlobalKey();
  double? _lastChildWidth;

  /// Centers the scroll position on the row content (no-op when the content
  /// fits the viewport). Called after layout; re-runs when the content width
  /// changes (zoom change).
  void _centerIfNeeded() {
    if (!_controller.hasClients) return;
    final ctx = _childKey.currentContext;
    if (ctx == null) return;
    final childWidth = ctx.size?.width ?? 0;
    final viewport = _controller.position.viewportDimension;
    if (_lastChildWidth == childWidth) return;
    _lastChildWidth = childWidth;
    final target =
        ((childWidth - viewport) / 2).clamp(0.0, double.maxFinite);
    _controller.jumpTo(target);
  }

  void _scheduleCenter() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerIfNeeded());
  }

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _scheduleCenter();
  }

  @override
  void didUpdateWidget(_RowScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCenter();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        return SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          child: KeyedSubtree(
            key: _childKey,
            // Canvas at least as wide as the viewport so the centered row
            // stays centered when it fits, and can scroll when it overflows.
            //
            // [SizeChangedLayoutNotifier] catches the row growing from the
            // placeholder width to the real spread width when the bitmaps
            // land. That growth does not rebuild this widget (the `_PageItem`
            // setState is internal), so `didUpdateWidget` alone never fired
            // and the row stayed anchored at its old 0 offset -- the spread
            // looked shifted to the left until the next zoom / mode change.
            child: NotificationListener<SizeChangedLayoutNotification>(
              onNotification: (_) {
                _scheduleCenter();
                return true;
              },
              child: SizeChangedLayoutNotifier(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: viewportWidth),
                  child: Center(child: widget.child),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Double-page flip mode (FEATURES 3.1.3): PageView, step 2, no scrollbar.
///
/// Navigation:
/// - Wheel scroll flips pages (throttled 250ms, FEATURES 8.8). The wheel
///   drives the [PageController] directly; `onPageChanged` (fires once the
///   animation settles) syncs the state. Ctrl+wheel is zoom (handled by the
///   outer listener in ReaderPage), so it is skipped here.
/// - Toolbar / outline / thumbnail jumps change `currentPage`; the
///   [viewerProvider] listener animates the PageView to the matching pair.
///
/// Each page pair is centered at physical size × zoom (scale-from-center;
/// overflow is clipped symmetrically).
class _DoublePageFlip extends ConsumerStatefulWidget {
  const _DoublePageFlip({
    required this.pageCount,
    required this.bookId,
    required this.zoom,
    required this.dpiScale,
    required this.placeholderHeight,
    required this.placeholderWidth,
  });

  final int pageCount;
  final int bookId;
  final double zoom;
  final double dpiScale;
  final double placeholderHeight;
  final double placeholderWidth;

  @override
  ConsumerState<_DoublePageFlip> createState() => _DoublePageFlipState();
}

class _DoublePageFlipState extends ConsumerState<_DoublePageFlip> {
  late final PageController _pageController;
  late final ProviderSubscription _pageSub;
  // The pair that is currently shown (updated only when the PageView settles).
  int _stablePair = 0;
  // Target pair of the last animation request (used as the base for further
  // flips while an animation is still running).
  int? _lastAnimTarget;
  // Wheel throttling: Linux emits a burst of wheel events per notch; only the
  // first event of a burst (same direction within 250ms) flips one pair.
  DateTime _lastWheelAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastWheelDir = 0;

  @override
  void initState() {
    super.initState();
    final startPage = ref.read(viewerProvider).currentPage;
    _stablePair = (startPage - 1) ~/ 2;
    _pageController = PageController(initialPage: _stablePair);
    // External page changes (toolbar / jump / outline / thumbnails) drive the
    // PageView to the matching pair.
    _pageSub = ref.listenManual(
      viewerProvider.select((s) => s.currentPage),
      (prev, next) {
        if (!_pageController.hasClients) return;
        final targetPair = (next - 1) ~/ 2;
        if (targetPair == _stablePair) return;
        _animateTo(targetPair);
      },
    );
  }

  @override
  void dispose() {
    _pageSub.close();
    _pageController.dispose();
    super.dispose();
  }

  /// Animates to [targetPair], remembering the target as the base for wheel
  /// accumulation while the animation is running.
  void _animateTo(int targetPair) {
    if (!_pageController.hasClients) return;
    final clamped = targetPair.clamp(0, _pairCount - 1);
    if (clamped == _stablePair && _lastAnimTarget == null) return;
    _lastAnimTarget = clamped;
    _pageController
        .animateToPage(
          clamped,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(() {
          // Cleared only if no newer animation replaced this one.
          if (_lastAnimTarget == clamped) _lastAnimTarget = null;
        });
  }

  /// Wheel -> flip one page pair per wheel gesture. Ctrl+wheel is zoom
  /// (handled by the outer listener). A single wheel notch on Linux produces
  /// a burst of PointerScrollEvents; the throttle collapses the burst into
  /// exactly one flip (FEATURES 8.8).
  void _onPointerSignal(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isControlPressed) return; // zoom gesture
    final now = DateTime.now();
    final dir = signal.scrollDelta.dy > 0 ? 1 : -1;
    if (now.difference(_lastWheelAt).inMilliseconds < 250 &&
        dir == _lastWheelDir) {
      return; // same-direction repeat within the throttle window
    }
    _lastWheelAt = now;
    _lastWheelDir = dir;
    _animateTo(_stablePair + dir);
  }

  /// Fires after the PageView settles on a pair; sync the reader state.
  void _onPageChanged(int pairIndex) {
    _stablePair = pairIndex;
    final page = pairIndex * 2 + 1;
    if (page != ref.read(viewerProvider).currentPage) {
      ref.read(viewerProvider.notifier).setPage(page);
    }
  }

  int get _pairCount => (widget.pageCount / 2).ceil();

  @override
  Widget build(BuildContext context) {
    final cache = ref.read(bitmapCacheProvider);
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.horizontal,
        itemCount: _pairCount,
        // Pre-render the adjacent spread so a swipe lands on a painted page.
        allowImplicitScrolling: true,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, pairIndex) {
          final leftPage = pairIndex * 2;
          final rightPage = leftPage + 1;
          // OverflowBox releases the viewport width constraint so the pair
          // Row keeps its true size when zoomed past the viewport; ClipRect
          // crops symmetrically (center-anchored) and no RenderFlex overflow
          // warning is emitted.
          return ClipRect(
            child: Center(
              child: OverflowBox(
                alignment: Alignment.center,
                maxWidth: double.infinity,
                maxHeight: double.infinity,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _PageItem(
                      cache: cache,
                      bookId: widget.bookId,
                      page: leftPage,
                      zoom: widget.zoom,
                      dpiScale: widget.dpiScale,
                      placeholderHeight: widget.placeholderHeight,
                      placeholderWidth: widget.placeholderWidth,
                      onPageHeightKnown: (h) =>
                          ref.read(pageHeightProvider.notifier).state = h,
                      onPageWidthKnown: (w) =>
                          ref.read(pageWidthProvider.notifier).state = w,
                    ),
                    const SizedBox(width: kGutter),
                    if (rightPage < widget.pageCount)
                      _PageItem(
                        cache: cache,
                        bookId: widget.bookId,
                        page: rightPage,
                        zoom: widget.zoom,
                        dpiScale: widget.dpiScale,
                        placeholderHeight: widget.placeholderHeight,
                        placeholderWidth: widget.placeholderWidth,
                        onPageHeightKnown: (h) =>
                            ref.read(pageHeightProvider.notifier).state = h,
                        onPageWidthKnown: (w) =>
                            ref.read(pageWidthProvider.notifier).state = w,
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A single page: fetches the bitmap from the cache and lays it out at
/// `physical_size × zoom` (no width clamping). The parent is responsible for
/// centering; this widget only sizes itself. On top of the bitmap it stacks
/// the annotation layers (FEATURES 4.3: highlight layer + selection layer).
class _PageItem extends ConsumerStatefulWidget {
  const _PageItem({
    required this.cache,
    required this.bookId,
    required this.page,
    required this.zoom,
    required this.dpiScale,
    this.placeholderHeight = 0,
    this.placeholderWidth = 0,
    this.onPageHeightKnown,
    this.onPageWidthKnown,
  });

  final BitmapCache cache;
  final int bookId;
  final int page; // 0-indexed
  final double zoom;
  final double dpiScale;

  /// Display height used by the loading placeholder, so items keep a stable
  /// height (matching the real page height once known) and the scroll offset ↔
  /// page mapping stays exact.
  final double placeholderHeight;

  /// Display width used by the loading placeholder. The double modes need it:
  /// a zero-width placeholder collapses the spread row to its gutter and the
  /// row jumps sideways when the bitmaps arrive.
  final double placeholderWidth;

  /// Reports the page's display height (logical px) *after* the bitmap loads
  /// (async -- never invoked during build, so it is safe to touch providers).
  final void Function(double height)? onPageHeightKnown;

  /// Reports the page's display width, same timing as [onPageHeightKnown].
  final void Function(double width)? onPageWidthKnown;

  @override
  ConsumerState<_PageItem> createState() => _PageItemState();
}

class _PageItemState extends ConsumerState<_PageItem> {
  ui.Image? _image;
  double? _lastReportedHeight;
  double? _lastReportedWidth;

  /// The zoom actually used to render `_image` (quantized to a cache tier).
  /// Used to recover the page's physical size; kept with the image so a stale
  /// bitmap (while a new tier loads) is measured with its own render zoom
  /// instead of the new one -- preventing size jumps / overlaps on zoom change.
  double _imageRenderZoom = 1.0;
  // True while a sharpen re-render (stage 2) is in flight.
  bool _sharpening = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_PageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload when the page, the DPI, or the zoom tier (which decides the
    // render resolution) changed -- zooming in re-renders sharper.
    if (oldWidget.page != widget.page ||
        oldWidget.dpiScale != widget.dpiScale ||
        BitmapCache.quantizeZoom(oldWidget.zoom) !=
            BitmapCache.quantizeZoom(widget.zoom)) {
      _load();
    }
  }

  /// Render priority: the page(s) on screen go first, neighbours after.
  /// pdfium serializes all renders, so without this a fast scroll could queue
  /// several cacheExtent pages ahead of the one the reader is looking at.
  int get _renderPriority {
    final viewer = ref.read(viewerProvider);
    final current = viewer.currentPage - 1; // 0-indexed
    if (widget.page == current) return 0;
    if (viewer.mode == ViewMode.doublePage && widget.page == current + 1) {
      return 0;
    }
    return 1;
  }

  Future<void> _load() async {
    final renderZoom = BitmapCache.quantizeZoom(widget.zoom);
    final img = await widget.cache.getOrFetch(
      bookId: widget.bookId,
      page: widget.page,
      zoom: renderZoom,
      dpiScale: widget.dpiScale,
      priority: _renderPriority,
    );
    if (!mounted) return;
    setState(() {
      _image = img;
      _imageRenderZoom = renderZoom;
    });
    // Report the page's physical height (pt, zoom-independent) for exact
    // scroll-based page tracking. Storing the physical height (not the
    // display height) keeps it constant across within-tier zoom nudges, so
    // the alignment stride never goes stale when the zoom changes inside a
    // 0.5 tier (the display height = physical × zoom is computed at use).
    // Runs asynchronously (never during build).
    if (widget.onPageHeightKnown != null && img != null) {
      final physicalH = img.height / (renderZoom * widget.dpiScale);
      if (physicalH != _lastReportedHeight) {
        _lastReportedHeight = physicalH;
        widget.onPageHeightKnown!(physicalH);
      }
    }
    // The physical width feeds the placeholder width of not-yet-loaded pages
    // in the double modes (a zero-width placeholder shifts the spread row).
    if (widget.onPageWidthKnown != null && img != null) {
      final physicalW = img.width / (renderZoom * widget.dpiScale);
      if (physicalW != _lastReportedWidth) {
        _lastReportedWidth = physicalW;
        widget.onPageWidthKnown!(physicalW);
      }
    }
  }

  /// Stage-2 sharpen: when the display needs more pixels than the current
  /// bitmap provides (display zoom > quantized render tier), re-render at the
  /// exact display resolution so the page stays crisp (FEATURES 3.6.2).
  void _maybeSharpen(double displayW) {
    if (_image == null || _sharpening) return;
    final image = _image!;
    final pagePtW = image.width / (_imageRenderZoom * widget.dpiScale);
    // Pixels needed to display the page 1:1 on screen.
    final neededPx = displayW * widget.dpiScale;
    if (neededPx <= image.width * 1.02) return; // already sharp enough
    // Render zoom that provides those pixels (rounded up to a 0.5 step so we
    // never re-render on tiny zoom nudges).
    final displayZoom = neededPx / pagePtW;
    final renderZoom = ((displayZoom * 2).ceil() / 2).clamp(0.5, 4.0);
    if (renderZoom <= _imageRenderZoom) return;
    _sharpening = true;
    widget.cache
        .getOrFetch(
          bookId: widget.bookId,
          page: widget.page,
          zoom: renderZoom,
          dpiScale: widget.dpiScale,
          priority: 0,
        )
        .then((img) {
      _sharpening = false;
      if (!mounted || img == null) return;
      setState(() {
        _image = img;
        _imageRenderZoom = renderZoom;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      // Placeholder sized to the page's expected size (the measured page size
      // once known, else an A4-ratio estimate) so the layout stays stable
      // while rendering. The width is not optional in the double modes: a
      // zero-width placeholder collapses the spread row to its gutter, and
      // the row then jumps sideways once the bitmaps arrive.
      final estWidth = MediaQuery.sizeOf(context).width * widget.zoom;
      final pw = widget.placeholderWidth > 0
          ? widget.placeholderWidth
          : estWidth * 0.707;
      final ph = widget.placeholderHeight > 0
          ? widget.placeholderHeight
          : pw * 1.414;
      return SizedBox(
        width: pw,
        height: ph,
        child: const _PagePlaceholder(),
      );
    }

    final image = _image!;
    // Recover the page's physical size in logical pixels from the rendered
    // bitmap (which was rendered at `_imageRenderZoom × dpiScale`).
    final pagePtW = image.width / (_imageRenderZoom * widget.dpiScale);
    final pagePtH = image.height / (_imageRenderZoom * widget.dpiScale);

    // Display at physical size × zoom -- no clamping ("不要给文档内层设置
    // 大小限制"); the parent centers the page so zoom is scale-from-center.
    final displayW = pagePtW * widget.zoom;
    final displayH = pagePtH * widget.zoom;

    // Ensure the rendered resolution matches the display (may trigger a
    // sharper re-render).
    _maybeSharpen(displayW);

    final theme = Theme.of(context);
    // Annotations of this page: the highlight layer paints them, the
    // selection layer hit-tests taps against them.
    final pageAnns = ref.watch(annotationProvider.select((a) {
      final list = a.valueOrNull;
      if (list == null) return const <TextAnnotation>[];
      // Only marks made on the ORIGINAL page: marks from the 对照 view's
      // translated pane carry the same page number but live at different
      // positions (v9 `source`).
      return list
          .where((x) =>
              x.page == widget.page &&
              AnnotationPane.fromSource(x.source) == AnnotationPane.original)
          .toList(growable: false);
    }));

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: RepaintBoundary(
        child: SizedBox(
          width: displayW,
          height: displayH,
          // Two sibling boundaries inside the page:
          //  - the bitmap (with its theme color filter, which forces a
          //    saveLayer) is its own layer, so selection drags / OCR markers
          //    / search hits never re-rasterize a multi-megapixel page;
          //  - all vector overlays share one layer, which is cheap to repaint.
          // Before the split, every selection-drag frame repainted the whole
          // page and this was the reader's main source of jank.
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: ThemedPageImage(image: image),
                ),
              ),
              Positioned.fill(
                child: RepaintBoundary(
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned.fill(
                        child: HighlightLayer(annotations: pageAnns),
                      ),
                      // Low-confidence OCR lines marked for review (7.1.6).
                      Positioned.fill(
                        child: LowConfidenceLayer(
                          bookId: widget.bookId,
                          page: widget.page,
                        ),
                      ),
                      // Search hit highlight (M6, 3.5.3): below the selection
                      // layer so selection previews stay visible on top.
                      Positioned.fill(
                        child: HitHighlightLayer(
                          bookId: widget.bookId,
                          page: widget.page,
                        ),
                      ),
                      Positioned.fill(
                        child: SelectionLayer(
                          bookId: widget.bookId,
                          page: widget.page,
                          annotations: pageAnns,
                          // Touch: long-press to select so drags still scroll.
                          longPressSelect:
                              PlatformHost.current.touch,
                        ),
                      ),
                      // Image-layer marks (FEATURES §5): painted above the
                      // selection layer; when a mark tool is armed this layer
                      // captures the pointer events, otherwise it is
                      // hit-test transparent.
                      Positioned.fill(
                        child: ImageMarkLayer(page: widget.page),
                      ),
                      // Scan prompt (FEATURES 7.1.2): anchored to this page's
                      // top-left corner so it scrolls with the page.
                      Positioned(
                        top: 8,
                        left: 8,
                        child: ScanOverlay(page: widget.page),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PagePlaceholder extends StatelessWidget {
  const _PagePlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
