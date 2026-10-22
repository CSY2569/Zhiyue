import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:rbwa/core/platform/platform.dart';

/// Dynamic refresh-rate hints for Android (30–120 Hz).
///
/// What this can and cannot do:
///  - The app cannot *render* faster than the display; it can only ask the
///    platform to run the panel at a higher rate while content is moving.
///  - Android 11+ exposes `Surface.setFrameRate`, a per-surface hint the
///    compositor honours without a visible mode switch. On older releases the
///    fallback is `WindowManager.LayoutParams.preferredRefreshRate`.
///  - When the UI goes still, no frames are produced, so LTPO panels already
///    drop on their own; the idle hint exists for panels that would otherwise
///    stay pinned at the app's preferred rate.
///
/// Policy: while the user is touching / scrolling, ask for the highest rate
/// the panel advertises (capped at [maxRate]); after [idleDelay] without
/// activity, ask for [minRate] (clamped to a supported mode).
class RefreshRateController {
  RefreshRateController._();

  static final RefreshRateController instance = RefreshRateController._();

  static const _channel = MethodChannel('rbwa/display');

  /// Ceiling the user asked for.
  static const double maxRate = 120;

  /// Idle floor: a static page does not need more than this.
  static const double minRate = 30;

  static const _idleDelay = Duration(milliseconds: 900);

  /// Advertised refresh rates (empty on desktop / unsupported devices).
  List<double> _supported = const [];
  double _activeRate = maxRate;
  double _idleRate = minRate;

  double _applied = 0;
  bool _active = false;
  Timer? _idleTimer;
  bool _initialized = false;

  /// Whether the platform bridge is usable.
  bool get supported =>
      PlatformBridge.isAndroid && _supported.isNotEmpty;

  /// Highest rate we will request (never above what the panel supports).
  double get activeRate => _activeRate;
  double get idleRate => _idleRate;

  /// Reads the display's modes once. Safe to call repeatedly; failures leave
  /// the controller disabled (desktop, unusual OEM surfaces).
  Future<void> init() async {
    if (_initialized || !PlatformBridge.isAndroid) return;
    _initialized = true;
    try {
      final info = await _channel.invokeMethod<Map>('info');
      final rates = <double>[
        for (final n in (info?['supportedRates'] as List?) ?? const [])
          if (n is num && n >= 24) n.toDouble(),
      ];
      if (rates.isEmpty) return;
      rates.sort();
      _supported = rates;
      // Cap the active rate at 120 and pick the closest advertised mode;
      // prefer not to LOWER the panel below its own maximum on high-refresh
      // devices (e.g. 90Hz panels stay at 90).
      final top = rates.reduce((a, b) => a > b ? a : b);
      _activeRate = top > maxRate ? _nearest(maxRate) : top;
      _idleRate = _nearest(minRate);
      // Start idle: the first screen is static until the user touches it.
      _apply(_idleRate);
    } catch (e) {
      debugPrint('refresh-rate probe failed: $e');
    }
  }

  /// Called by pointer / scroll activity. Cheap: only touches the channel on
  /// an idle -> active transition.
  void notifyActivity() {
    if (!supported) return;
    _idleTimer?.cancel();
    if (!_active) {
      _active = true;
      _apply(_activeRate);
    }
    _idleTimer = Timer(_idleDelay, () {
      _active = false;
      _apply(_idleRate);
    });
  }

  /// Immediately drop to the idle rate (e.g. when leaving the reader).
  void goIdle() {
    _idleTimer?.cancel();
    _active = false;
    _apply(_idleRate);
  }

  /// Requests [fps] (already clamped by the platform side too).
  void _apply(double fps) {
    if (!supported || fps <= 0) return;
    // Avoid re-sending the same hint every gesture.
    if ((_applied - fps).abs() < 0.5) return;
    _applied = fps;
    _channel.invokeMethod<double>('setFrameRate', {'fps': fps}).catchError(
      (Object e) {
        debugPrint('setFrameRate($fps) failed: $e');
        return null;
      },
    );
  }

  /// Nearest advertised rate to [target] (handles 59.94 / 119.88 modes).
  double _nearest(double target) {
    var best = _supported.first;
    var bestDelta = (best - target).abs();
    for (final r in _supported) {
      final d = (r - target).abs();
      if (d < bestDelta) {
        best = r;
        bestDelta = d;
      }
    }
    return best;
  }
}

/// Feeds pointer/scroll activity into [RefreshRateController].
///
/// A [Listener] catches direct touches; [NotificationListener] catches scroll
/// notifications that bubble up from lists. Both only bump a timer, so the
/// cost per event is a microsecond-scale check -- no rebuilds.
class RefreshRateScope extends StatefulWidget {
  const RefreshRateScope({super.key, required this.child});

  final Widget? child;

  @override
  State<RefreshRateScope> createState() => _RefreshRateScopeState();
}

class _RefreshRateScopeState extends State<RefreshRateScope> {
  @override
  void initState() {
    super.initState();
    RefreshRateController.instance.init();
  }

  @override
  void dispose() {
    RefreshRateController.instance.goIdle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => RefreshRateController.instance.notifyActivity(),
      onPointerMove: (_) => RefreshRateController.instance.notifyActivity(),
      onPointerSignal: (_) => RefreshRateController.instance.notifyActivity(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) {
          RefreshRateController.instance.notifyActivity();
          return false;
        },
        child: widget.child ?? const SizedBox.shrink(),
      ),
    );
  }
}
