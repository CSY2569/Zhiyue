import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reader page wraps its scaffold in a ReadingThemeScope', () {
    final src =
        File('lib/features/reader/reader_page.dart').readAsStringSync();
    expect(src.contains('ReadingThemeScope('), isTrue,
        reason:
            'reader_page.dart must wrap the reader Scaffold in ReadingThemeScope');
  });
}
