import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('translated pane card is theme-driven, not hardcoded white', () {
    final src = File('lib/features/bilingual/widgets/translated_pane.dart')
        .readAsStringSync();
    expect(src.contains('Colors.white'), isFalse,
        reason: 'the translated page card must come from the theme '
            '(surfaceContainerLow), not a hardcoded white');
    expect(src.contains('surfaceContainerLow'), isTrue);
  });

  test('translated page bitmap uses ThemedPageImage', () {
    final src = File('lib/features/bilingual/widgets/translated_pane.dart')
        .readAsStringSync();
    expect(src.contains('ThemedPageImage('), isTrue,
        reason: 'translated bitmaps get the same reading-theme tint as '
            'original pages');
  });
}
