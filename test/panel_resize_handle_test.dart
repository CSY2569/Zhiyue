import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/widgets/panel_resize_handle.dart';

void main() {
  testWidgets('drag reports horizontal deltas, end reports completion',
      (tester) async {
    final deltas = <double>[];
    var ended = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: PanelResizeHandle(
            onResize: deltas.add,
            onResizeEnd: () => ended++,
          ),
        ),
      ),
    ));

    await tester.drag(find.byType(PanelResizeHandle), const Offset(40, 0));
    await tester.pumpAndSettle();

    expect(deltas, isNotEmpty);
    expect(deltas.reduce((a, b) => a + b), closeTo(40, 0.5));
    expect(ended, 1);
  });

  testWidgets('vertical drags report no net horizontal delta', (tester) async {
    final deltas = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(child: PanelResizeHandle(onResize: deltas.add)),
      ),
    ));

    await tester.drag(find.byType(PanelResizeHandle), const Offset(0, 40));
    await tester.pumpAndSettle();

    // The pure-horizontal recognizer may still win the arena with dx == 0;
    // what matters is that no width change is reported.
    final total = deltas.fold<double>(0, (a, b) => a + b);
    expect(total, closeTo(0, 0.001));
  });
}
