import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/features/reader/providers/reader_tap_provider.dart';

void main() {
  test('tap zones split at 18% / 82%', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerTapProvider.notifier);

    ReaderTapZone? zoneFor(double x) {
      notifier.report(x);
      return container.read(readerTapProvider)?.zone;
    }

    expect(zoneFor(0.0), ReaderTapZone.leftEdge);
    expect(zoneFor(0.17), ReaderTapZone.leftEdge);
    expect(zoneFor(0.18), ReaderTapZone.center);
    expect(zoneFor(0.5), ReaderTapZone.center);
    expect(zoneFor(0.82), ReaderTapZone.center);
    expect(zoneFor(0.83), ReaderTapZone.rightEdge);
    expect(zoneFor(1.0), ReaderTapZone.rightEdge);
  });

  test('every report increments seq so listeners see repeated taps', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(readerTapProvider.notifier);

    notifier.report(0.9);
    final first = container.read(readerTapProvider)!;
    notifier.report(0.9);
    final second = container.read(readerTapProvider)!;
    expect(second.seq, greaterThan(first.seq));
    expect(second.zone, first.zone);
  });
}
