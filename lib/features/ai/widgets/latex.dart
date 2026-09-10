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
/// display math would be eaten as two inline formulas.
///
/// Inline `$...$` tolerates spaces just inside the delimiters (`$ x + 1 $`),
/// which models commonly emit -- the strict "no whitespace after the opening
/// `$`" rule silently dropped those formulas into plain text. Currency
/// (`价格 $100 和 $200`) is instead rejected during matching: the closing `$`
/// may not be followed by a digit, and [LatexInlineSyntax._looksLikeCurrency]
/// drops digit-bearing bodies that carry no LaTeX / math / letter signal
/// (covers the spaced form `$ 100 和 $ 200`). Inline bodies stay single-line.
class LatexInlineSyntax extends md.InlineSyntax {
  LatexInlineSyntax() : super(_pattern);

  static const String _pattern =
      r'\$\$([\s\S]+?)\$\$'
      r'|\\\(([\s\S]+?)\\\)'
      r'|\\\[([\s\S]+?)\\\]'
      r'|(?<![\w$])\$[ \t]*([^$\n]*?\S)[ \t]*\$(?!\d)';

  /// Any LaTeX command, operator, grouping or ASCII letter marks the body as
  /// real math rather than a currency amount.
  static final RegExp _mathSignal = RegExp(r'[\\^_{}=+\-*/<>|]|[A-Za-z]');
  static final RegExp _digit = RegExp(r'\d');

  /// True for a digit-bearing body with no math signal (e.g. `100 和` from
  /// `$ 100 和 $ 200`) -- treated as currency, never as a formula.
  static bool _looksLikeCurrency(String tex) =>
      _digit.hasMatch(tex) && !_mathSignal.hasMatch(tex);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    // Groups 1/3 are display math ($$..$$ / \[..\]), 2/4 inline.
    final display = match[1] != null || match[3] != null;
    final tex = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '').trim();
    if (tex.isEmpty || (!display && _looksLikeCurrency(tex))) {
      // Whitespace-only body (`$$ $$`) or a currency amount: keep raw text.
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
