import 'package:flutter/material.dart';

import 'package:rbwa/src/rust/models/annotation.dart';

/// Icon for a text annotation kind (shared by the notes sidebar and the
/// note popup).
IconData textAnnotationIcon(TextAnnotationKind kind) {
  switch (kind) {
    case TextAnnotationKind.highlight:
      return Icons.border_color;
    case TextAnnotationKind.underline:
      return Icons.format_underlined;
    case TextAnnotationKind.strikethrough:
      return Icons.format_strikethrough;
    case TextAnnotationKind.note:
      return Icons.edit_note;
  }
}
