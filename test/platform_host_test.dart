import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/layout_breakpoints.dart';
import 'package:rbwa/platform/platform_host.dart';

/// A host that reports touch input, without any platform channels.
class _TouchHost extends PlatformHost {
  const _TouchHost();

  @override
  bool get touch => true;
}

/// A host that reports a mouse + keyboard.
class _MouseHost extends PlatformHost {
  const _MouseHost();

  @override
  bool get touch => false;
}

void main() {
  tearDown(() => PlatformHost.install(const _MouseHost()));

  group('layout predicates', () {
    test('phone layout needs both touch and a narrow screen', () {
      PlatformHost.install(const _TouchHost());
      expect(PlatformHost.current.phoneLayout(360), isTrue,
          reason: 'a phone is touch and narrow');
      // A 776dp tablet is touch but wide: it keeps the side-column layout.
      // Collapsing these two predicates made tablets render the phone layout
      // (drawer, single bilingual pane) -- a regression this test pins.
      expect(PlatformHost.current.phoneLayout(776), isFalse);

      PlatformHost.install(const _MouseHost());
      expect(PlatformHost.current.phoneLayout(360), isFalse,
          reason: 'a narrow desktop window is not a phone');
    });

    test('compact controls react to touch OR a narrow window', () {
      PlatformHost.install(const _TouchHost());
      expect(PlatformHost.current.compactUi(1280), isTrue,
          reason: 'a landscape tablet must not overflow a single row');

      PlatformHost.install(const _MouseHost());
      expect(PlatformHost.current.compactUi(1280), isFalse);
      expect(PlatformHost.current.compactUi(600), isTrue,
          reason: 'a narrow desktop window still needs the compact form');
    });

    test('the width breakpoint itself is platform-free', () {
      expect(isCompactWidth(699), isTrue);
      expect(isCompactWidth(700), isFalse);
    });
  });
}
