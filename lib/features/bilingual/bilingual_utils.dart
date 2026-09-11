import 'package:flutter/material.dart';

import 'package:rbwa/src/rust/models/translate.dart';

/// Substitutes inline formula placeholder tokens (`⟨prefix-MATH_n⟩`, plan
/// §4.3) with the region's original text for display. The token prefix is
/// random per request and not persisted, so substitution is by the `_n`
/// index against [regions] (which is stored in the same order).
///
/// Unknown indices / missing regions keep the token text so nothing is
/// silently dropped.
String substituteFormulaTokens(
  String translated,
  List<FormulaRegion> regions,
) {
  if (translated.isEmpty || !translated.contains('MATH_')) return translated;
  final re = RegExp(r'⟨[^⟨⟩]*-MATH_(\d+)⟩');
  return translated.replaceAllMapped(re, (m) {
    final idx = int.tryParse(m.group(1)!);
    if (idx != null && idx >= 0 && idx < regions.length) {
      return regions[idx].sourceText;
    }
    return m.group(0)!;
  });
}

/// Human-readable label + color for a paragraph's translation status
/// (plan §5 段落状态).
(String, Color) paragraphStatusStyle(ParagraphStatus status, ColorScheme cs) {
  switch (status) {
    case ParagraphStatus.pending:
      return ('待翻译', cs.outline);
    case ParagraphStatus.translating:
      return ('翻译中', cs.primary);
    case ParagraphStatus.done:
      return ('', cs.outline);
    case ParagraphStatus.lowConfidence:
      return ('低置信,请核对', cs.tertiary);
    case ParagraphStatus.failed:
      return ('翻译失败', cs.error);
    case ParagraphStatus.formulaCheck:
      return ('公式需核对', cs.tertiary);
  }
}
