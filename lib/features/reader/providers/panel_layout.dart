import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart'
    show SidebarType;

/// User-adjustable sizes for the reader's panels (FEATURES 3.4.4 / 6.4):
/// the three sidebars, the AI side panel and the floating AI result card.
///
/// Every panel was a hardcoded width before; this makes them draggable and
/// remembers the result. Persisted to the `settings` KV table through the
/// [SettingsRepository] (mirrors [ThemeController] / [OutlineExpandAll]);
/// all values are in logical pixels.
class PanelLayout {
  const PanelLayout({
    this.thumbnailsWidth = 180,
    this.outlineWidth = 240,
    this.annotationsWidth = 240,
    this.aiPanelWidth = 320,
    this.cardSize = const Size(440, 360),
  });

  final double thumbnailsWidth;
  final double outlineWidth;
  final double annotationsWidth;
  final double aiPanelWidth;
  final Size cardSize;

  /// Width of [type]'s sidebar.
  double widthFor(SidebarType type) {
    switch (type) {
      case SidebarType.thumbnails:
        return thumbnailsWidth;
      case SidebarType.outline:
        return outlineWidth;
      case SidebarType.annotations:
        return annotationsWidth;
    }
  }

  PanelLayout copyWith({
    double? thumbnailsWidth,
    double? outlineWidth,
    double? annotationsWidth,
    double? aiPanelWidth,
    Size? cardSize,
  }) =>
      PanelLayout(
        thumbnailsWidth: thumbnailsWidth ?? this.thumbnailsWidth,
        outlineWidth: outlineWidth ?? this.outlineWidth,
        annotationsWidth: annotationsWidth ?? this.annotationsWidth,
        aiPanelWidth: aiPanelWidth ?? this.aiPanelWidth,
        cardSize: cardSize ?? this.cardSize,
      );

  /// Replace [type]'s sidebar width, leaving the others untouched.
  PanelLayout withSidebarWidth(SidebarType type, double width) {
    switch (type) {
      case SidebarType.thumbnails:
        return copyWith(thumbnailsWidth: width);
      case SidebarType.outline:
        return copyWith(outlineWidth: width);
      case SidebarType.annotations:
        return copyWith(annotationsWidth: width);
    }
  }

  /// Width bounds for the sidebars / AI panel.
  static const double minSidebarWidth = 160;
  static const double maxSidebarWidth = 480;
  static const double minAiPanelWidth = 240;
  static const double maxAiPanelWidth = 560;

  /// Size bounds for the floating result card.
  static const double minCardWidth = 300;
  static const double maxCardWidth = 900;
  static const double minCardHeight = 220;
  static const double maxCardHeight = 700;

  static double _clampAiPanel(double w) =>
      w.clamp(minAiPanelWidth, maxAiPanelWidth);
}

/// Manages [PanelLayout] with KV persistence. Resizing during a drag updates
/// only the in-memory state ([resizeSidebar] etc.); [commit] writes the final
/// values once the gesture ends.
class PanelLayoutNotifier extends Notifier<PanelLayout> {
  static const _kOutline = 'panel_width_outline';
  static const _kThumbnails = 'panel_width_thumbnails';
  static const _kAnnotations = 'panel_width_annotations';
  static const _kAiPanel = 'panel_width_ai';
  static const _kCardSize = 'card_size';

  @override
  PanelLayout build() {
    _hydrate();
    return const PanelLayout();
  }

  Future<void> _hydrate() async {
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final outline = await repo.getSetting(_kOutline);
      final thumbs = await repo.getSetting(_kThumbnails);
      final notes = await repo.getSetting(_kAnnotations);
      final ai = await repo.getSetting(_kAiPanel);
      final card = await repo.getSetting(_kCardSize);
      state = state.copyWith(
        outlineWidth: _parseWidth(outline, PanelLayout.minSidebarWidth,
            PanelLayout.maxSidebarWidth),
        thumbnailsWidth: _parseWidth(thumbs, PanelLayout.minSidebarWidth,
            PanelLayout.maxSidebarWidth),
        annotationsWidth: _parseWidth(notes, PanelLayout.minSidebarWidth,
            PanelLayout.maxSidebarWidth),
        aiPanelWidth: _parseWidth(ai, PanelLayout.minAiPanelWidth,
            PanelLayout.maxAiPanelWidth),
        cardSize: _parseSize(card),
      );
    } catch (_) {
      // Core not ready yet (e.g. during tests); keep the defaults.
    }
  }

  double? _parseWidth(String? raw, double min, double max) {
    if (raw == null) return null;
    return double.tryParse(raw)?.clamp(min, max);
  }

  Size? _parseSize(String? raw) {
    if (raw == null) return null;
    final parts = raw.split('x');
    if (parts.length != 2) return null;
    final w = double.tryParse(parts[0]);
    final h = double.tryParse(parts[1]);
    if (w == null || h == null) return null;
    return Size(
      w.clamp(PanelLayout.minCardWidth, PanelLayout.maxCardWidth),
      h.clamp(PanelLayout.minCardHeight, PanelLayout.maxCardHeight),
    );
  }

  /// Widen / narrow one sidebar by [dx] logical pixels.
  void resizeSidebar(SidebarType type, double dx) {
    final next = (state.widthFor(type) + dx)
        .clamp(PanelLayout.minSidebarWidth, PanelLayout.maxSidebarWidth);
    state = state.withSidebarWidth(type, next);
  }

  /// Widen / narrow the AI side panel by [dx] logical pixels.
  void resizeAiPanel(double dx) {
    state = state.copyWith(
      aiPanelWidth: PanelLayout._clampAiPanel(state.aiPanelWidth + dx),
    );
  }

  /// Resize the floating result card by a drag [delta].
  void resizeCard(Offset delta) {
    state = state.copyWith(
      cardSize: Size(
        (state.cardSize.width + delta.dx)
            .clamp(PanelLayout.minCardWidth, PanelLayout.maxCardWidth),
        (state.cardSize.height + delta.dy)
            .clamp(PanelLayout.minCardHeight, PanelLayout.maxCardHeight),
      ),
    );
  }

  /// Persist the current sizes (called when a drag ends).
  Future<void> commit() async {
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final s = state;
      await repo.setSetting(_kOutline, s.outlineWidth.toString());
      await repo.setSetting(_kThumbnails, s.thumbnailsWidth.toString());
      await repo.setSetting(_kAnnotations, s.annotationsWidth.toString());
      await repo.setSetting(_kAiPanel, s.aiPanelWidth.toString());
      await repo.setSetting(
          _kCardSize, '${s.cardSize.width}x${s.cardSize.height}');
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory size still applies.
    }
  }
}

/// Riverpod provider for the adjustable panel layout.
final panelLayoutProvider =
    NotifierProvider<PanelLayoutNotifier, PanelLayout>(PanelLayoutNotifier.new);
