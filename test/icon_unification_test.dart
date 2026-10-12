import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the icon unification (FEATURES 8.12): the whole app uses Lucide
/// line icons (no Material `Icons.*` references) and chrome-icon sizes stay
/// on the 16 / 20 / 24 ladder. Empty-state emblems (40+) are exempt.
void main() {
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  test('no Material Icons references remain in lib', () {
    final offenders = <String>[];
    for (final f in files) {
      final src = f.readAsStringSync();
      if (RegExp(r'\bIcons\.[a-zA-Z]').hasMatch(src)) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'these files still use Material icons; use LucideIcons');
  });

  test('chrome icons stay on the 16/20/24 size ladder', () {
    final offenders = <String>[];
    final sizePattern = RegExp(r'size: (\d+)\b');
    bool allowed(int n) => n == 16 || n == 20 || n == 24 || n >= 40;
    for (final f in files) {
      for (final line in f.readAsLinesSync()) {
        for (final m in sizePattern.allMatches(line)) {
          final n = int.parse(m.group(1)!);
          if (!allowed(n)) {
            offenders.add('${f.path}: $line'.trim());
            break;
          }
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'icon sizes must be 16 / 20 / 24 (or a 40+ emblem)');
  });
}
