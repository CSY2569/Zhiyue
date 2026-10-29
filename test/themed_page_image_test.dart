import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/features/reader/widgets/themed_page_image.dart';

import 'helpers/test_images.dart';

void main() {
  // decodeImageFromPixels needs the real event loop, so images are created
  // outside testWidgets (its FakeAsync zone never delivers the callback).
  late final ui.Image whiteImage;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    whiteImage = await solidTestImage(const Color(0xFFFFFFFF));
  });

  testWidgets('page bitmap is wrapped in the palette color filter (night)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forReadingTheme(ReadingTheme.night),
        home: Scaffold(body: ThemedPageImage(image: whiteImage)),
      ),
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    // The filter must wrap ONLY the bitmap: RawImage is its direct child.
    final filtered = tester.widget<ColorFiltered>(find.byType(ColorFiltered));
    expect(filtered.child, isA<RawImage>());
  });

  testWidgets('light themes tint the image paint instead of adding a layer',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forReadingTheme(ReadingTheme.paper),
        home: Scaffold(body: ThemedPageImage(image: whiteImage)),
      ),
    );
    // No ColorFiltered: in a spread (two pages side by side) a colour-filter
    // layer per page made the first page render blank.
    expect(find.byType(ColorFiltered), findsNothing);
    final raw = tester.widget<RawImage>(find.byType(RawImage));
    expect(raw.color, ReadingPalette.paper.pageTint);
    expect(raw.colorBlendMode, BlendMode.multiply);
  });

  testWidgets('falls back to paper when no palette is in scope',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ThemedPageImage(image: whiteImage))),
    );
    // No crash without a ReadingPalette extension; the tint still applies.
    expect(find.byType(RawImage), findsOneWidget);
    expect(find.byType(ColorFiltered), findsNothing);
  });
}
