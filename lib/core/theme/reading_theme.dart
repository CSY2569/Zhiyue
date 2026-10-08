import 'package:flutter/material.dart';

/// Built-in reading themes (FEATURES 8.11): 纸白 / 羊皮纸 / 暗夜, plus `auto`
/// which follows the app brightness (light -> paper, dark -> night).
enum ReadingTheme { auto, paper, parchment, night }

/// Parses a persisted value back into a [ReadingTheme]; null on unknown.
ReadingTheme? parseReadingTheme(String raw) {
  for (final t in ReadingTheme.values) {
    if (t.name == raw) return t;
  }
  return null;
}

/// Resolves the effective theme: an explicit choice always wins; `auto`
/// maps the effective app brightness (light -> paper, dark -> night).
ReadingTheme resolveReadingTheme(
  ReadingTheme choice,
  ThemeMode mode,
  Brightness platformBrightness,
) {
  if (choice != ReadingTheme.auto) return choice;
  final dark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system && platformBrightness == Brightness.dark);
  return dark ? ReadingTheme.night : ReadingTheme.paper;
}

/// Colors and bitmap filters for one reading theme. Delivered as a
/// [ThemeExtension] so every widget under the reader route can read it via
/// `Theme.of(context).extension<ReadingPalette>()`.
@immutable
class ReadingPalette extends ThemeExtension<ReadingPalette> {
  const ReadingPalette({
    required this.theme,
    required this.brightness,
    required this.canvas,
    required this.pageCard,
    required this.placeholder,
    required this.primaryText,
    this.pageTint,
    this.nightMatrix,
  });

  final ReadingTheme theme;
  final Brightness brightness;

  /// Reader canvas behind the page cards (scaffold background).
  final Color canvas;

  /// Card surface for the translated pane / floating reader panels.
  final Color pageCard;

  /// Page placeholder while a bitmap renders.
  final Color placeholder;

  /// Body text on the reading surface (translated text path, chrome text).
  final Color primaryText;

  /// Multiply tint for page bitmaps (light themes): white areas take the
  /// tint, ink stays dark. Null on the night palette.
  final Color? pageTint;

  /// Invert + hue-rotate-180 matrix (night only): white page -> #1F2022,
  /// black ink -> #B9BDC3, illustration hues preserved. 20 doubles.
  final List<double>? nightMatrix;

  ColorFilter get pageColorFilter => nightMatrix != null
      ? ColorFilter.matrix(nightMatrix!)
      : ColorFilter.mode(pageTint!, BlendMode.multiply);

  static const paper = ReadingPalette(
    theme: ReadingTheme.paper,
    brightness: Brightness.light,
    canvas: Color(0xFFF4F2ED),
    pageCard: Color(0xFFFFFFFF),
    placeholder: Color(0xFFE8E5DE),
    primaryText: Color(0xFF2B2B28),
    pageTint: Color(0xFFFDFBF7),
  );

  static const parchment = ReadingPalette(
    theme: ReadingTheme.parchment,
    brightness: Brightness.light,
    canvas: Color(0xFFEDE3CC),
    pageCard: Color(0xFFFBF5E4),
    placeholder: Color(0xFFE2D6BA),
    primaryText: Color(0xFF463727),
    pageTint: Color(0xFFF5ECD4),
  );

  static const night = ReadingPalette(
    theme: ReadingTheme.night,
    brightness: Brightness.dark,
    canvas: Color(0xFF131417),
    pageCard: Color(0xFF1F2022),
    placeholder: Color(0xFF26272B),
    primaryText: Color(0xFFB9BDC3),
    nightMatrix: _nightMatrix,
  );

  static const _nightMatrix = <double>[
    0.347, -0.864, -0.087, 0, 185, //
    -0.262, -0.265, -0.089, 0, 189,
    -0.269, -0.902, 0.540, 0, 195,
    0, 0, 0, 1, 0,
  ];

  @override
  ReadingPalette copyWith({
    ReadingTheme? theme,
    Brightness? brightness,
    Color? canvas,
    Color? pageCard,
    Color? placeholder,
    Color? primaryText,
    Color? pageTint,
    List<double>? nightMatrix,
  }) {
    return ReadingPalette(
      theme: theme ?? this.theme,
      brightness: brightness ?? this.brightness,
      canvas: canvas ?? this.canvas,
      pageCard: pageCard ?? this.pageCard,
      placeholder: placeholder ?? this.placeholder,
      primaryText: primaryText ?? this.primaryText,
      pageTint: pageTint ?? this.pageTint,
      nightMatrix: nightMatrix ?? this.nightMatrix,
    );
  }

  @override
  ReadingPalette lerp(ReadingPalette? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Maps a (resolved, non-auto) theme to its palette. `auto` defensively
/// falls back to paper -- callers must run [resolveReadingTheme] first.
ReadingPalette readingPaletteFor(ReadingTheme theme) {
  switch (theme) {
    case ReadingTheme.paper:
      return ReadingPalette.paper;
    case ReadingTheme.parchment:
      return ReadingPalette.parchment;
    case ReadingTheme.night:
      return ReadingPalette.night;
    case ReadingTheme.auto:
      return ReadingPalette.paper;
  }
}
