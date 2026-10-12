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

  testWidgets('paper theme still wraps with its multiply tint',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forReadingTheme(ReadingTheme.paper),
        home: Scaffold(body: ThemedPageImage(image: whiteImage)),
      ),
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
  });

  testWidgets('falls back to paper when no palette is in scope',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ThemedPageImage(image: whiteImage))),
    );
    // No crash without a ReadingPalette extension; filter still applies.
    expect(find.byType(ColorFiltered), findsOneWidget);
  });
}
