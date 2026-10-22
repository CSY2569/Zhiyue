import 'package:flutter/services.dart';

import 'package:rbwa/platform/platform_host.dart';

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
    if (!PlatformHost.current.touch) return;
    HapticFeedback.selectionClick();
  }

  static void select() {
    if (!PlatformHost.current.touch) return;
    HapticFeedback.mediumImpact();
  }

  static void success() {
    if (!PlatformHost.current.touch) return;
    HapticFeedback.lightImpact();
  }

  static void warning() {
    if (!PlatformHost.current.touch) return;
    HapticFeedback.heavyImpact();
  }
}
