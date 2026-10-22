import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/lru_cache.dart';
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
  // The translated pane owns its decoded images: evicted entries are
  // disposed instead of waiting for the finalizer.
  final LruCache<_CacheKey, ui.Image> _cache =
      LruCache(maxEntries: _maxEntries, onEvict: (_, image) => image.dispose());
  final Map<_CacheKey, Future<ui.Image?>> _pending = {};

  /// Bumped by every clear; a render that started before the bump must not
  /// write its (stale) result back into the cleared cache.
  int _generation = 0;

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

    final cached = _cache.get(key);
    if (cached != null) {
      return TranslatedPageImage(image: cached, hasTranslation: true);
    }

    // Deduplicate concurrent renders of the same key (ListView layout passes
    // can ask for one page several times in a frame).
    final pending = _pending[key];
    if (pending != null) {
      final img = await pending;
      return TranslatedPageImage(image: img, hasTranslation: img != null);
    }

    final generation = _generation;
    final future = _render(key, bookId, page, generation);
    _pending[key] = future;
    try {
      final img = await future;
      return TranslatedPageImage(
        image: img,
        hasTranslation: img != null,
        error: img == null ? '译文页渲染失败' : null,
      );
    } finally {
      if (identical(_pending[key], future)) _pending.remove(key);
    }
  }

  Future<ui.Image?> _render(
    _CacheKey key,
    int bookId,
    int page,
    int generation,
  ) async {
    try {
      final bmp = await _repo.renderTranslatedPage(
        bookId: bookId,
        page: page,
        targetWidthPx: key.widthTier,
      );
      if (bmp.error != null || bmp.rgba.isEmpty) return null;
      final image = await decodeRgbaImage(bmp.width, bmp.height, bmp.rgba);
      if (image == null) return null;
      // The translation was replaced/deleted while rendering: the image is
      // from the old artifact and belongs to no one.
      if (generation != _generation) {
        image.dispose();
        return null;
      }
      _cache.put(key, image);
      return image;
    } catch (_) {
      return null;
    }
  }

  /// Drop every cached page of [bookId] (translation replaced or deleted).
  ///
  /// Pending renders of that book are dropped too: keeping them would let a
  /// request started before the revision bump finish and re-insert the OLD
  /// artifact's page into the cache that was just cleared.
  void clearBook(int bookId) {
    _cache.removeWhere((key, _) => key.bookId == bookId);
    _pending.removeWhere((key, _) => key.bookId == bookId);
    _generation++;
  }

  void clearAll() {
    _cache.clear();
    _pending.clear();
    _generation++;
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