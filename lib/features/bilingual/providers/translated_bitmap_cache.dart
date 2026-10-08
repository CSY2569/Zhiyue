import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/bilingual/providers/book_translation_provider.dart'
    show TranslatedPageImage, translationRevisionProvider;
import 'package:rbwa/features/reader/providers/image_decoder.dart';

/// Cache key: (bookId, page, widthTier). Pages are 1-indexed (as the engine's
/// mono PDF), matching `renderTranslatedPage`.
typedef _CacheKey = ({int bookId, int page, int widthTier});

/// LRU cache of rendered TRANSLATED pages (the 对照 view's right pane).
///
/// Mirrors the original pane's [BitmapCache] but fixes two things that made
/// the translated pane the app's main scroll cost:
///   * renders at the DISPLAY width (bucketed into tiers) instead of a fixed
///     3.0 dpi -- a narrow split pane needs ~4-6x fewer pixels per page;
///   * disposes evicted `ui.Image`s (the original cache leaks them to the
///     finalizer) and clears per book when the artifact changes, so a
///     re-translation never shows stale pages.
///
/// Entries survive provider disposal, so scrolling back is a cache hit.
class TranslatedBitmapCache {
  TranslatedBitmapCache(this._repo);

  final TranslationRepository _repo;
  final LinkedHashMap<_CacheKey, ui.Image> _cache = LinkedHashMap();
  final Map<_CacheKey, Future<ui.Image?>> _pending = {};

  /// The translated pane shows ~1-3 pages at a time; 12 tiers-deep covers
  /// back-scroll without the original cache's ~180MB footprint.
  static const int _maxEntries = 12;

  /// Pixel-width bucket (256px): small resizes / zoom steps reuse one render.
  static const int _tierStep = 256;

  static int widthTier(int targetWidthPx) =>
      ((targetWidthPx.clamp(256, 4096) + _tierStep ~/ 2) ~/ _tierStep) *
      _tierStep;

  /// The cached (or freshly rendered + decoded) page image.
  Future<TranslatedPageImage> getOrFetch({
    required int bookId,
    required int page,
    required int targetWidthPx,
  }) async {
    final key = (bookId: bookId, page: page, widthTier: widthTier(targetWidthPx));

    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // refresh recency
      return TranslatedPageImage(image: cached, hasTranslation: true);
    }

    // Deduplicate concurrent renders of the same key (ListView layout passes
    // can ask for one page several times in a frame).
    final pending = _pending[key];
    if (pending != null) {
      final img = await pending;
      return TranslatedPageImage(image: img, hasTranslation: img != null);
    }

    final future = _render(key, bookId, page);
    _pending[key] = future;
    try {
      final img = await future;
      return TranslatedPageImage(
        image: img,
        hasTranslation: img != null,
        error: img == null ? '译文页渲染失败' : null,
      );
    } finally {
      _pending.remove(key);
    }
  }

  Future<ui.Image?> _render(_CacheKey key, int bookId, int page) async {
    try {
      final bmp = await _repo.renderTranslatedPage(
        bookId: bookId,
        page: page,
        targetWidthPx: key.widthTier,
      );
      if (bmp.error != null || bmp.rgba.isEmpty) return null;
      final image = await decodeRgbaImage(bmp.width, bmp.height, bmp.rgba);
      if (image == null) return null;
      _evictIfNeeded();
      _cache[key] = image;
      return image;
    } catch (_) {
      return null;
    }
  }

  void _evictIfNeeded() {
    while (_cache.length >= _maxEntries) {
      _cache.remove(_cache.keys.first)?.dispose();
    }
  }

  /// Drop every cached page of [bookId] (translation replaced or deleted).
  void clearBook(int bookId) {
    _cache.removeWhere((key, image) {
      if (key.bookId != bookId) return false;
      image.dispose();
      return true;
    });
  }

  void clearAll() {
    for (final image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }
}

/// Singleton cache; wipes itself whenever ANY translation artifact changes
/// (revision bump) so stale pages never outlive their translation.
final translatedBitmapCacheProvider = Provider<TranslatedBitmapCache>((ref) {
  final cache = TranslatedBitmapCache(ref.read(translationRepositoryProvider));
  ref.listen<int>(translationRevisionProvider, (prev, next) {
    if (prev != next) cache.clearAll();
  });
  ref.onDispose(cache.clearAll);
  return cache;
});