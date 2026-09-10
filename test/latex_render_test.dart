import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/ai/widgets/message_bubble.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// LaTeX rendering in AI message bubbles (Markdown + LaTeX, FEATURES 6.2):
/// `$...$` / `$$...$$` / `\(...\)` / `\[...\]` become real equations via
/// flutter_math_fork; unclosed (still streaming) and unsupported formulas
/// degrade to plain text instead of breaking the bubble.
Future<void> pumpBubble(
  WidgetTester tester,
  String content, {
  bool streaming = false,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: AiMessageBubble(
          role: AiRole.assistant,
          content: content,
          streaming: streaming,
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('inline \$...\$ renders a Math widget, no raw dollars left',
      (tester) async {
    await pumpBubble(tester, r'质能方程 $E=mc^2$ 是著名的公式。');
    expect(find.byType(Math), findsOneWidget);
    // The delimiters must not leak into the rendered text.
    expect(find.textContaining(r'$'), findsNothing);
    // Surrounding prose still renders.
    expect(find.textContaining('质能方程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('display \$\$...\$\$ on its own lines renders (multiline body)',
      (tester) async {
    await pumpBubble(tester, r'计算下式：' '\n\n' r'$$' '\n'
        r'\frac{a}{b} + \sum_{i=0}^{n} i' '\n' r'$$' '\n\n' r'如上。');
    expect(find.byType(Math), findsOneWidget);
    expect(find.textContaining(r'frac'), findsNothing);
    expect(find.textContaining('计算下式'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(r'\(...\) and \[...\] delimiters render too', (tester) async {
    await pumpBubble(tester, r'方程 \(x^2+1\) 有解，且' '\n\n'
        r'\[a^2+b^2=c^2\]' '\n\n' r'成立。');
    // One inline + one display formula.
    expect(find.byType(Math), findsNWidgets(2));
    expect(find.textContaining(r'\('), findsNothing);
    expect(find.textContaining(r'\['), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported TeX falls back to the raw source, no crash',
      (tester) async {
    await pumpBubble(tester, r'奇怪的命令 $\notacommand{x}$ 出现了。');
    // Math wraps its onErrorFallback when parsing fails: the raw $...$
    // source stays visible instead of throwing or vanishing.
    expect(find.textContaining(r'$\notacommand{x}$'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unclosed \$ during streaming stays plain text (no Math)',
      (tester) async {
    // The formula is still being streamed: only "$E=mc^2" has arrived.
    await pumpBubble(tester, r'推导中 $E=mc^2', streaming: true);
    expect(find.byType(Math), findsNothing);
    // Raw text (with the cursor paragraph) is visible, nothing lost.
    expect(find.textContaining(r'$E=mc^2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('currency \$ amounts are not mistaken for formulas',
      (tester) async {
    await pumpBubble(tester, r'价格 $100 和 $200 之间。');
    expect(find.byType(Math), findsNothing);
    await pumpBubble(tester, r'单价$100，总价$200，不空格也是货币。');
    expect(find.byType(Math), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('formulas inside code spans stay literal', (tester) async {
    // Code spans take precedence: the math source itself must not render.
    await pumpBubble(tester, r'源码 `$x^2$` 里的公式保持原文。');
    expect(find.byType(Math), findsNothing);
    expect(find.textContaining(r'$x^2$'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
