import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a tap landed on the reading content.
enum ReaderTapZone {
  /// Left 18% of the page: previous page.
  leftEdge,

  /// Middle: toggle the mobile chrome (top / bottom bars).
  center,

  /// Right 18% of the page: next page.
  rightEdge,
}

/// One reported tap: a monotonically increasing [seq] plus the [zone], so a
/// listener can act on every tap even when two taps share a zone.
class ReaderTapEvent {
  const ReaderTapEvent({required this.seq, required this.zone});

  final int seq;
  final ReaderTapZone zone;
}

/// Touch taps on the reading page that were NOT consumed by text selection,
/// annotation taps or mark tools.
///
/// The selection layer is the only widget that reliably sees taps over the
/// page (it is the top opaque layer), and it lives several widgets below the
/// reader page. Rather than threading a callback through the page → scroll →
/// item chain, the layer reports here and the reader page listens.
///
/// Zones are only meaningful on phones; the reader ignores the events on
/// desktop (where a click is a click).
class ReaderTapController extends Notifier<ReaderTapEvent?> {
  int _seq = 0;

  @override
  ReaderTapEvent? build() => null;

  /// [normX] is the tap position in normalized page coordinates (0..1).
  void report(double normX) {
    final zone = normX < 0.18
        ? ReaderTapZone.leftEdge
        : normX > 0.82
            ? ReaderTapZone.rightEdge
            : ReaderTapZone.center;
    state = ReaderTapEvent(seq: ++_seq, zone: zone);
  }
}

final readerTapProvider =
    NotifierProvider<ReaderTapController, ReaderTapEvent?>(
  ReaderTapController.new,
);
