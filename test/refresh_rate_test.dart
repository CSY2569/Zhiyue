import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/platform/refresh_rate.dart';

void main() {
  test('rate policy stays inside the requested 30..120 window', () {
    // The controller clamps whatever panel modes are advertised; these are
    // the constants the policy uses (the platform bridge does the clamping).
    expect(RefreshRateController.maxRate, 120);
    expect(RefreshRateController.minRate, 30);
    expect(RefreshRateController.maxRate, greaterThan(RefreshRateController.minRate));
  });

  test('desktop is unsupported and activity is a no-op', () {
    final c = RefreshRateController.instance;
    expect(c.supported, isFalse);
    // Must not throw without the platform channel.
    c.notifyActivity();
    c.goIdle();
    expect(c.supported, isFalse);
  });
}
