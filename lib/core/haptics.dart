import 'package:flutter/services.dart';

import 'package:rbwa/core/platform/platform.dart';

/// Centralized haptic feedback.
///
/// Android's `HapticFeedback` maps to the platform's own patterns; the calls
/// are no-ops on desktop (Flutter swallows them), but gating on [isMobile]
/// avoids pointless platform-channel traffic on every tap.
///
/// Keep the vocabulary small and consistent:
///  - [tap]: a page turn, a toolbar action;
///  - [select]: a long-press selection / word pick;
///  - [success]: OCR finished, translation cached;
///  - [warning]: a failed action that the user should notice.
class Haptics {
  const Haptics._();

  static void tap() {
    if (!PlatformCapabilities.current().isMobile) return;
    HapticFeedback.selectionClick();
  }

  static void select() {
    if (!PlatformCapabilities.current().isMobile) return;
    HapticFeedback.mediumImpact();
  }

  static void success() {
    if (!PlatformCapabilities.current().isMobile) return;
    HapticFeedback.lightImpact();
  }

  static void warning() {
    if (!PlatformCapabilities.current().isMobile) return;
    HapticFeedback.heavyImpact();
  }
}
