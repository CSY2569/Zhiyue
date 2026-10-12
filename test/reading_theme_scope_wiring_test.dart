import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('app.dart resolves the reading theme into the global MaterialApp theme',
      () {
    final src = File('lib/app.dart').readAsStringSync();
    expect(src.contains('forReadingTheme('), isTrue,
        reason:
            'app.dart must pass AppTheme.forReadingTheme(effective) as the '
            'app-wide theme so the whole UI follows the reading theme');
  });

  test('reader page no longer applies a local reading-theme scope', () {
    final src =
        File('lib/features/reader/reader_page.dart').readAsStringSync();
    expect(src.contains('ReadingThemeScope('), isFalse,
        reason: 'the reader route follows the global theme; the local '
            'ReadingThemeScope wrap was removed');
  });
}
