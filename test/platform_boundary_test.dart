import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the branch boundary described in `.platform/README.md`.
///
/// `main` builds the desktop app and must not reference Android-only code;
/// the `android` branch owns those files. Without this test a stray import
/// would only fail on one branch, long after the commit that introduced it.
///
/// The check is skipped on the Android branch, where the files legitimately
/// exist.
void main() {
  final root = Directory.current;

  // Presence of the implementation, not the manifest: the manifest lists the
  // paths on both branches so the sync script knows what to restore.
  final isAndroid =
      Directory('${root.path}/lib/platform/android').existsSync();

  test('platform boundary holds on this branch', () {
    if (isAndroid) {
      // Android branch: the platform files are supposed to be here.
      expect(
        Directory('${root.path}/lib/platform/android').existsSync(),
        isTrue,
        reason: 'the android branch must carry lib/platform/android/',
      );
      return;
    }

    // --- desktop branch ----------------------------------------------------
    // Only tracked sources matter: a local `android/build/` or `.gradle/`
    // left over from a previous checkout is gitignored and harmless.
    final gradleSources = [
      'android/app/build.gradle.kts',
      'android/settings.gradle.kts',
      'android/app/src/main/AndroidManifest.xml',
    ].where((p) => File('${root.path}/$p').existsSync()).toList();
    expect(
      gradleSources,
      isEmpty,
      reason: 'main must not carry the Android Gradle project',
    );
    expect(
      Directory('${root.path}/lib/platform/android').existsSync(),
      isFalse,
      reason: 'main must not carry the Android platform host',
    );

    const banned = <String>[
      'lib/platform/android/',
      'phone_reader_chrome.dart',
      'translated_text_column.dart',
      'page_text_translation_provider.dart',
      'text_translation_repository.dart',
      'refresh_rate.dart',
      'core/platform/platform.dart',
    ];

    final offenders = <String>[];
    for (final entity in Directory('${root.path}/lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // The branch selector legitimately names the Android host in a comment.
      if (entity.path.endsWith('lib/platform/current.dart')) continue;
      final source = entity.readAsStringSync();
      for (final needle in banned) {
        if (source.contains(needle)) {
          offenders.add('${entity.path}: $needle');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'desktop branch references Android-only code:\n${offenders.join('\n')}',
    );
  });

  test('no widget checks the OS directly for layout', () {
    // Layout differences must go through PlatformHost / isCompactWidth, not
    // ad-hoc Platform.is*. Reading the OS for a *runtime budget* (render DPI,
    // default animation durations) is fine, so only the widget layer is
    // checked here.
    final offenders = <String>[];
    for (final entity in Directory('${root.path}/lib/platform').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.contains('/platform/android/')) continue;
      // The host contract explains in a comment why it exists; only real
      // code lines count.
      final code = entity
          .readAsLinesSync()
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      if (code.contains('Platform.isAndroid') ||
          code.contains('Platform.isIOS')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });
}
