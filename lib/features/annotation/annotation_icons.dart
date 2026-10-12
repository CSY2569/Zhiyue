import 'package:flutter/material.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/src/rust/models/annotation.dart';

/// Icon for a text annotation kind (shared by the notes sidebar and the
/// note popup).
IconData textAnnotationIcon(TextAnnotationKind kind) {
  switch (kind) {
    case TextAnnotationKind.highlight:
      return LucideIcons.highlighter;
    case TextAnnotationKind.underline:
      return LucideIcons.underline;
    case TextAnnotationKind.strikethrough:
      return LucideIcons.strikethrough;
    case TextAnnotationKind.note:
      return LucideIcons.penLine;
  }
}
