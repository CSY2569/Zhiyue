import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_flutter/lucide_flutter.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/layout_metrics.dart';
import 'package:rbwa/core/widgets/app_overlay.dart';
import 'package:rbwa/core/widgets/confirm_dialog.dart';
import 'package:rbwa/core/widgets/text_input_dialog.dart';

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// The radius actually painted by a DecoratedBox / Material shape.
double? _radiusOf(Widget widget) {
  if (widget is DecoratedBox) {
    final deco = widget.decoration;
    if (deco is BoxDecoration) {
      final r = deco.borderRadius;
      if (r is BorderRadius) {
        final b = r.resolve(TextDirection.ltr);
        return b.topLeft.x;
      }
    }
  }
  return null;
}

void main() {
  test('overlay tokens are shared', () {
    // Every modal surface uses this one radius.
    expect(Golden.radiusPanel, 18);
    expect(Golden.panelShadow(Brightness.light), isNotEmpty);
  });

  testWidgets('confirm dialog uses the panel radius and serif title',
      (tester) async {
    await tester.pumpWidget(_host(
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showConfirmDialog(
            context,
            title: '删除书籍',
            content: '确定删除？',
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Material's stock AlertDialog (28dp radius) must not be used.
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(AppDialog), findsOneWidget);

    // The panel surface carries the shared radius.
    final radii = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map(_radiusOf)
        .whereType<double>();
    expect(radii, contains(Golden.radiusPanel));

    // Serif title, like the library header.
    final title = tester.widget<Text>(find.text('删除书籍'));
    expect(title.style?.fontFamily, 'serif');
    // Destructive action is tinted with the error colour.
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text input dialog uses the same shell and rounded field',
      (tester) async {
    await tester.pumpWidget(_host(
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showTextInputDialog(context, title: '新建文件夹'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(AppDialog), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    final border = field.decoration?.border;
    expect(border, isA<OutlineInputBorder>());
    expect(field.decoration?.filled, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('app sheet paints a rounded panel with a grab handle',
      (tester) async {
    await tester.pumpWidget(_host(
      Builder(
        builder: (context) => FilledButton(
          onPressed: () => showAppSheet(
            context,
            title: '移动到文件夹',
            children: [
              AppSheetItem(
                icon: LucideIcons.folder,
                label: '小说',
                onTap: () {},
              ),
            ],
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AppSheet), findsOneWidget);
    expect(find.text('移动到文件夹'), findsOneWidget);
    expect(find.text('小说'), findsOneWidget);
    final radii = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map(_radiusOf)
        .whereType<double>();
    expect(radii, contains(Golden.radiusPanel));
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme themes popup menus and snackbars to the panel language',
      (tester) async {
    final theme = AppTheme.light();
    final scheme = theme.colorScheme;
    expect(theme.popupMenuTheme.color, scheme.surfaceContainerLow);
    expect(
      (theme.popupMenuTheme.shape as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(Golden.radiusPanel),
    );
    expect(theme.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(theme.bottomSheetTheme.backgroundColor, Colors.transparent);
    expect(theme.chipTheme.shape, isA<StadiumBorder>());
  });
}
