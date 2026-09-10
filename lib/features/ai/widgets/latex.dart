/// LaTeX formula rendering for AI answers (Markdown + LaTeX, FEATURES 6.2).
///
/// AI messages are rendered with flutter_markdown. Formulas embedded by the
/// model -- `$...$` / `$$...$$` / `\(...\)` / `\[...\]`, the four delimiter
/// styles LLMs commonly emit -- are lifted out as `<latex>` elements by a
/// custom inline syntax and rendered as real equations with flutter_math_fork
/// (pure Dart, no webview, works offline).
///
/// Streaming resilience: a not-yet-closed delimiter (the formula is still
/// arriving chunk by chunk) simply does not match and shows as plain text
/// until it closes; TeX the parser rejects falls back to the raw source via
/// [Math.onErrorFallback] instead of throwing.

library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;

/// Renders `<latex>` elements produced by [LatexInlineSyntax].
class LatexElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final tex = element.textContent.trim();
    if (tex.isEmpty) return null;
    final display = element.attributes['display'] == 'true';
    // Match the bubble's paragraph style (bodySmall 12sp + theme color) so
    // the formula follows the surrounding text and both light/dark themes.
    final theme = Theme.of(context);
    final def = DefaultTextStyle.of(context).style;
    final base = parentStyle ?? preferredStyle ?? def;
    final style = TextStyle(
      fontSize: base.fontSize ?? def.fontSize ?? 14,
      color: base.color ?? def.color ?? theme.colorScheme.onSurface,
    );
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      // Unsupported TeX (or half-streamed content): show the raw source,
      // never a crash or a silently missing formula.
      onErrorFallback: (_) => Text(
        display ? '\$\$$tex\$\$' : '\$$tex\$',
        style: style,
      ),
    );
    if (display) {
      // KaTeX-like display math: its own centered line.
      return Center(
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: math),
      );
    }
    return math;
  }
}

/// Recognizes the four LaTeX delimiter styles inside Markdown text.
///
/// Alternation order matters: `$$` must be tried before `$`, otherwise
/// display math would be eaten as two inline formulas. The inline `$...$`
/// branch guards against currency false positives (`价格 $100 和 $200` /
/// `价格$100，总计$200`): the char before the opening `$` must not be a word
/// char or `$`, the content must not start/end with whitespace, span lines,
/// or contain `$`, and the closing `$` must not be followed by a digit.
class LatexInlineSyntax extends md.InlineSyntax {
  LatexInlineSyntax() : super(_pattern);

  static const String _pattern =
      r'\$\$([\s\S]+?)\$\$'
      r'|\\\(([\s\S]+?)\\\)'
      r'|\\\[([\s\S]+?)\\\]'
      r'|(?<![\w$])\$(?![\s$])([^$\n]+?)(?<!\s)\$(?!\d)';

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // Groups 1/3 are display math ($$..$$ / \[..\]), 2/4 inline.
    final display = match[1] != null || match[3] != null;
    final tex = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '').trim();
    if (tex.isEmpty) {
      // Whitespace-only body (e.g. "$$ $$"): keep the raw text.
      parser.addNode(md.Text(match[0]!));
      return true;
    }
    final element = md.Element.text('latex', tex);
    if (display) element.attributes['display'] = 'true';
    parser.addNode(element);
    return true;
  }
}

/// Wiring for [MarkdownBody]: `inlineSyntaxes: latexInlineSyntaxes,
/// builders: latexBuilders`.
final List<md.InlineSyntax> latexInlineSyntaxes = [LatexInlineSyntax()];
final Map<String, MarkdownElementBuilder> latexBuilders = {
  'latex': LatexElementBuilder(),
};
