import 'dart:ui' show Offset, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/settings/settings_store.dart';
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
  /// The reading area (PdfPageScroll) keeps at least this width when the
  /// left sidebar and AI panel are open (plan §1 v4.2 同开时的最小宽度).
  /// Panels opened later take priority.
  static const double minContentWidth = 360;

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
    final repo = ref.read(settingsRepositoryProvider);
    final outline = await loadSetting(repo, _kOutline, (raw) => raw);
    final thumbs = await loadSetting(repo, _kThumbnails, (raw) => raw);
    final notes = await loadSetting(repo, _kAnnotations, (raw) => raw);
    final ai = await loadSetting(repo, _kAiPanel, (raw) => raw);
    final card = await loadSetting(repo, _kCardSize, (raw) => raw);
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

  /// Clamp the AI panel to at most [max] (shared-space rule).
  void clampAiPanel(double max) {
    final next = state.aiPanelWidth.clamp(
        PanelLayout.minAiPanelWidth,
        max.clamp(PanelLayout.minAiPanelWidth, PanelLayout.maxAiPanelWidth));
    if (next != state.aiPanelWidth) {
      state = state.copyWith(aiPanelWidth: next);
    }
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
    final repo = ref.read(settingsRepositoryProvider);
    final s = state;
    await persistSetting(repo, _kOutline, s.outlineWidth.toString());
    await persistSetting(repo, _kThumbnails, s.thumbnailsWidth.toString());
    await persistSetting(repo, _kAnnotations, s.annotationsWidth.toString());
    await persistSetting(repo, _kAiPanel, s.aiPanelWidth.toString());
    await persistSetting(
        repo, _kCardSize, '${s.cardSize.width}x${s.cardSize.height}');
  }
}

/// Riverpod provider for the adjustable panel layout.
final panelLayoutProvider =
    NotifierProvider<PanelLayoutNotifier, PanelLayout>(PanelLayoutNotifier.new);
