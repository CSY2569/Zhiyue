import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:ui' show Offset;

import 'package:rbwa/src/rust/models/annotation.dart'
    show ImageAnnotation, ImageAnnotationKind;

/// Kind of an image-layer mark (FEATURES 5.1-5.4), matching the DB strings.
enum ImageMarkKind {
  brush('brush'),
  shape('shape'),
  sticky('sticky'),
  stamp('stamp');

  const ImageMarkKind(this.dbValue);

  final String dbValue;

  static ImageMarkKind fromDb(String s) => ImageMarkKind.values.firstWhere(
        (k) => k.dbValue == s,
        orElse: () => ImageMarkKind.brush,
      );
}

/// Style of an image-layer mark (FEATURES 5.5): color / stroke width / fill
/// / font size, serialized as the `style` JSON column.
class ImageMarkStyle {
  const ImageMarkStyle({
    this.color,
    this.strokeWidth = 3,
    this.fill = false,
    this.fontSize = 14,
  });

  /// Hex color string (#rrggbb); null = use the theme default.
  final String? color;
  final double strokeWidth;
  final bool fill;
  final double fontSize;

  String toJson() => jsonEncode({
        'color': color,
        'strokeWidth': strokeWidth,
        'fill': fill,
        'fontSize': fontSize,
      });

  factory ImageMarkStyle.fromJson(String json) {
    final v = jsonDecode(json);
    if (v is! Map<String, dynamic>) return const ImageMarkStyle();
    return ImageMarkStyle(
      color: v['color'] as String?,
      strokeWidth: (v['strokeWidth'] as num?)?.toDouble() ?? 3,
      fill: v['fill'] as bool? ?? false,
      fontSize: (v['fontSize'] as num?)?.toDouble() ?? 14,
    );
  }
}

/// One image-layer mark (FEATURES 5.1-5.5): normalized position (x, y =
/// center) + optional normalized size (w, h) + rotation + kind-specific JSON
/// `payload`. Mirrors the Rust `ImageAnnotation` row; `id <= 0` means not
/// persisted yet.
///
/// The JSON payload / style strings are decoded lazily and memoized: the
/// paint path reads them for every mark on every frame, and repeated
/// decodes of large brush paths are measurable (a few hundred marks would
/// otherwise decode hundreds of times per frame).
class ImageMark {
  ImageMark({
    this.id = 0,
    required this.page,
    required this.kind,
    required this.x,
    required this.y,
    this.w,
    this.h,
    this.rotation = 0,
    required this.payload,
    required this.style,
  });

  final int id;
  final int page; // 0-indexed
  final ImageMarkKind kind;
  final double x;
  final double y;
  final double? w;
  final double? h;
  final double rotation;
  final String payload;
  final String style;

  ImageMarkStyle? _styleCache;
  Map<String, dynamic>? _payloadCache;

  ImageMarkStyle get styleObj => _styleCache ??= ImageMarkStyle.fromJson(style);

  /// Normalized bounding rect (empty for pure point marks).
  Offset get topLeft => Offset(x - (w ?? 0) / 2, y - (h ?? 0) / 2);

  /// A mark contains [p] (normalized) when it has a size.
  bool containsNorm(Offset p) {
    final ww = w ?? 0;
    final hh = h ?? 0;
    if (ww <= 0 || hh <= 0) return false;
    return (p.dx - x).abs() <= ww / 2 && (p.dy - y).abs() <= hh / 2;
  }

  // --- Kind-specific payload accessors --------------------------------------

  /// Brush path points (normalized; FEATURES 5.1).
  List<Offset> get brushPoints {
    final v = _payloadValue;
    final pts = v?['points'];
    if (pts is! List) return const [];
    return [
      for (final p in pts)
        if (p is List && p.length >= 2)
          Offset((p[0] as num).toDouble(), (p[1] as num).toDouble()),
    ];
  }

  /// Sticky note text (FEATURES 5.2).
  String? get stickyText => _payloadValue?['text'] as String?;

  /// Stamp image file (relative to the app data dir; FEATURES 5.3).
  String? get stampFile => _payloadValue?['file'] as String?;

  /// Shape type: rect / ellipse / arrow (FEATURES 5.4).
  String? get shapeType => _payloadValue?['shapeType'] as String?;

  Map<String, dynamic>? get _payloadValue {
    final cached = _payloadCache;
    if (cached != null) return cached;
    final v = jsonDecode(payload);
    if (v is Map<String, dynamic>) {
      _payloadCache = v;
      return v;
    }
    return null;
  }

  ImageMark copyWith({
    int? id,
    double? x,
    double? y,
    double? w,
    double? h,
    double? rotation,
    String? payload,
    String? style,
  }) {
    return ImageMark(
      id: id ?? this.id,
      page: page,
      kind: kind,
      x: x ?? this.x,
      y: y ?? this.y,
      w: w ?? this.w,
      h: h ?? this.h,
      rotation: rotation ?? this.rotation,
      payload: payload ?? this.payload,
      style: style ?? this.style,
    );
  }

  /// Wrap a persisted Rust row.
  factory ImageMark.fromRust(ImageAnnotation a) => ImageMark(
        id: a.id,
        page: a.page,
        kind: ImageMarkKind.fromDb(a.kind.name),
        x: a.x,
        y: a.y,
        w: a.w,
        h: a.h,
        rotation: a.rotation,
        payload: a.payload,
        style: a.style,
      );
}

// --- Payload builders (mirror the JSON the Dart side reads back) ------------

/// Brush payload: the normalized path points (FEATURES 5.1).
String brushPayload(List<Offset> points) => jsonEncode({
      'points': [
        for (final p in points) [p.dx, p.dy],
      ],
    });

/// Sticky payload: the note text (FEATURES 5.2).
String stickyPayload(String text) => jsonEncode({'text': text});

/// Stamp payload: the image file (relative to the app data dir, 5.3).
String stampPayload(String file) => jsonEncode({'file': file});

/// Shape payload: rect / ellipse / arrow (FEATURES 5.4).
String shapePayload(String shapeType) => jsonEncode({'shapeType': shapeType});

/// Map a UI mark kind to the FRB enum (mirror of [ImageMarkKind.fromDb]).
ImageAnnotationKind imageMarkKindToRust(ImageMarkKind kind) =>
    switch (kind) {
      ImageMarkKind.brush => ImageAnnotationKind.brush,
      ImageMarkKind.shape => ImageAnnotationKind.shape,
      ImageMarkKind.sticky => ImageAnnotationKind.sticky,
      ImageMarkKind.stamp => ImageAnnotationKind.stamp,
    };
