import 'dart:ui' as ui;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/reader/providers/image_decoder.dart';

/// A rendered translated page for the bilingual pane.
class TranslatedPageImage {
  const TranslatedPageImage({
    this.image,
    this.width = 0,
    this.height = 0,
    this.hasTranslation = false,
    this.error,
  });

  final ui.Image? image;

  /// Rendered pixel size of the translated page (for aspect-ratio layout).
  final int width;
  final int height;

  /// False = the page has no current translation yet.
  final bool hasTranslation;
  final String? error;
}

/// Key for a rendered translated page.
typedef TranslatedPageKey = ({int bookId, int page, String targetLang});

/// Bumped after a page translation completes. Every [translatedPageImageProvider]
/// watches it, so finishing a translation re-renders the visible pages.
///
/// Regression: the auto-translate queue wrote to the DB but nothing
/// invalidated the pane, so the default 随进度 mode showed "尚未翻译" forever
/// (the reported "翻译功能无效" bug).
final translationRevisionProvider = StateProvider<int>((ref) => 0);

/// One visible page's rendered translation, keyed by (book, page, lang).
/// Rendering is expensive (builds + rasterizes a single-page PDF), so it runs
/// only when the page's translation is present, and re-runs when the revision
/// counter changes.
class TranslatedPageImageNotifier extends AutoDisposeFamilyAsyncNotifier<
    TranslatedPageImage, TranslatedPageKey> {
  @override
  Future<TranslatedPageImage> build(TranslatedPageKey arg) async {
    // Rebuild whenever a translation finishes (see [translationRevisionProvider]).
    ref.watch(translationRevisionProvider);
    final repo = ref.read(translationRepositoryProvider);
    try {
      final res = await repo.renderTranslatedPage(
        bookId: arg.bookId,
        page: arg.page,
        targetLang: arg.targetLang,
        // 3x keeps both the background raster and the re-drawn text crisp
        // on hi-dpi displays (bg is rendered at the same scale, so 1:1
        // pixels, no resampling blur).
        dpiScale: 3.0,
      );
      if (res.error != null) {
        return TranslatedPageImage(
          hasTranslation: res.hasTranslation,
          error: res.error,
        );
      }
      if (!res.hasTranslation) {
        return const TranslatedPageImage(hasTranslation: false);
      }
      final img = await decodeRgbaImage(res.width, res.height, res.rgba);
      return TranslatedPageImage(
        image: img,
        width: res.width,
        height: res.height,
        hasTranslation: true,
      );
    } catch (e) {
      return TranslatedPageImage(error: e.toString());
    }
  }
}

final translatedPageImageProvider = AsyncNotifierProvider.autoDispose.family<
    TranslatedPageImageNotifier,
    TranslatedPageImage,
    TranslatedPageKey>(TranslatedPageImageNotifier.new);
