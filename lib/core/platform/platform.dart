import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where the bilingual view gets its translation, per platform:
///  - desktop keeps the bundled RetainPDF (layout-preserving PDF) engine;
///  - Android uses the text-level pipeline (block LLM calls, no Python sidecar).
enum BilingualMode { retainPdf, text }

/// Platform capabilities that branch behavior without scattering
/// `Platform.isAndroid` checks through widgets.
class PlatformCapabilities {
  const PlatformCapabilities({
    required this.isMobile,
    required this.isAndroid,
    required this.bilingualMode,
  });

  /// Auto-detected capabilities for the running process.
  factory PlatformCapabilities.current() {
    final android = !kIsWeb && Platform.isAndroid;
    // iOS is not a target yet; treat any non-desktop as mobile so layout
    // code has one switch to reason about.
    final mobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    return PlatformCapabilities(
      isMobile: mobile,
      isAndroid: android,
      bilingualMode: android ? BilingualMode.text : BilingualMode.retainPdf,
    );
  }

  /// Touch-first layout: drawers / full-screen panels instead of fixed
  /// side columns.
  final bool isMobile;
  final bool isAndroid;

  /// Which bilingual implementation the reader shows.
  final BilingualMode bilingualMode;

  bool get usesRetainEngine => bilingualMode == BilingualMode.retainPdf;
  bool get usesTextTranslation => bilingualMode == BilingualMode.text;

  /// Narrow-enough layout to switch panels to modal/full-screen form.
  /// 700dp separates phones from tablets in the plan (A3).
  static bool isCompactWidth(double width) => width < 700;
}

/// Result of the Android first-run model install.
class OcrModelStatus {
  const OcrModelStatus({
    required this.installed,
    this.path = '',
    this.version = '',
    this.bytes = 0,
  });

  final bool installed;
  final String path;
  final String version;
  final int bytes;
}

/// Android platform bridge: model installation + native paths.
///
/// On desktop every method is a no-op so callers can stay platform-agnostic.
class PlatformBridge {
  PlatformBridge._();

  static const _models = MethodChannel('rbwa/models');
  static const _system = MethodChannel('rbwa/system');

  static bool _android = false;

  /// Whether the Android bridge is available (set by [init]).
  static bool get isAndroid => _android;

  /// One-time detection. Safe to call on desktop (no channels are invoked).
  static void init() {
    _android = !kIsWeb && Platform.isAndroid;
  }

  /// Copies the bundled OCR models into the app data dir (Android only).
  ///
  /// Returns immediately on desktop. [onProgress] receives 0..1 on Android.
  static Future<OcrModelStatus> ensureOcrModels({
    void Function(double progress, String file)? onProgress,
  }) async {
    if (!_android) {
      return const OcrModelStatus(installed: true);
    }
    _models.setMethodCallHandler((call) async {
      if (call.method == 'onProgress') {
        final args = (call.arguments as Map).cast<String, Object?>();
        final done = (args['done'] as num?)?.toDouble() ?? 0;
        final total = (args['total'] as num?)?.toDouble() ?? 0;
        if (total > 0) {
          onProgress?.call(done / total, (args['file'] as String?) ?? '');
        }
      }
      return null;
    });
    try {
      final result = await _models.invokeMethod<Map>('ensureInstalled');
      final map = (result ?? const {}).cast<String, Object?>();
      return OcrModelStatus(
        installed: map['installed'] == true,
        path: (map['path'] as String?) ?? '',
        version: (map['version'] as String?) ?? '',
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
      );
    } finally {
      _models.setMethodCallHandler(null);
    }
  }

  /// App-private files dir (Android) — the Rust core's data root.
  static Future<String?> filesDir() async {
    if (!_android) return null;
    final info = await systemInfo();
    return info?['filesDir'] as String?;
  }

  /// Whether the display stays awake while [on] is true (reading mode).
  /// No-op on desktop.
  static Future<void> setKeepScreenOn(bool on) async {
    if (!_android) return;
    try {
      await _system.invokeMethod<bool>('setKeepScreenOn', {'on': on});
    } on PlatformException {
      // Older builds without the method: ignore.
    } on MissingPluginException {
      // Same.
    }
  }

  /// Files delivered by ACTION_VIEW / ACTION_SEND (paths inside the app
  /// cache dir). Consumed once -- a second call returns an empty list.
  static Future<List<String>> takeIncomingFiles() async {
    if (!_android) return const [];
    try {
      final files = await _system.invokeMethod<List>('takeIncomingFiles');
      return (files ?? const []).whereType<String>().toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Native library dir (Android) — used to locate `libpdfium.so`.
  static Future<String?> nativeLibraryDir() async {
    if (!_android) return null;
    final info = await systemInfo();
    return info?['nativeLibraryDir'] as String?;
  }

  /// Device facts for OCR sizing / cache budgeting (Android only).
  static Future<Map<String, Object?>?> systemInfo() async {
    if (!_android) return null;
    try {
      final info = await _system.invokeMethod<Map>('info');
      return info?.cast<String, Object?>();
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Registers a callback for Android `onTrimMemory` (bitmap caches must drop
  /// before the OS kills the process).
  static void onTrimMemory(void Function(int level) handler) {
    if (!_android) return;
    _system.setMethodCallHandler((call) async {
      if (call.method == 'onTrimMemory') {
        final args = (call.arguments as Map).cast<String, Object?>();
        handler((args['level'] as num?)?.toInt() ?? 0);
      }
      return null;
    });
  }
}
