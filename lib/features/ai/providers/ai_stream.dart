import 'dart:async';

/// Wraps one streaming FRB subscription (FEATURES 6.3.1): accumulates chunks
/// into a buffer and exposes cancellation -- dropping the subscription
/// aborts the Rust request (6.3.2).
///
/// [onUpdate] is throttled: providers emit many small chunks (sometimes one
/// per token), and rebuilding the message bubble + Markdown on every chunk
/// drops frames. Updates are coalesced to at most one per [updateInterval],
/// while [onFinish] always delivers the complete text.
class AiStreamSession {
  StreamSubscription<String>? _sub;
  final StringBuffer _buffer = StringBuffer();

  /// Minimum spacing between [onUpdate] callbacks.
  static const Duration updateInterval = Duration(milliseconds: 80);

  Timer? _flushTimer;
  void Function(String text)? _onUpdate;
  String _lastEmitted = '';

  /// Start listening to [stream]; any previous session is cancelled first.
  /// [onUpdate] fires at most every [updateInterval] with the accumulated
  /// text; [onFinish] fires exactly once with the final text -- also on error,
  /// where [formatError] turns the raw exception into the message shown on the
  /// card / in the panel (errors are appended so they stay visible).
  void start(
    Stream<String> stream, {
    required void Function(String text) onUpdate,
    required void Function(String text) onFinish,
    String Function(Object e)? formatError,
  }) {
    cancel();
    _onUpdate = onUpdate;
    _lastEmitted = '';
    _sub = stream.listen(
      (chunk) {
        _buffer.write(chunk);
        _scheduleFlush();
      },
      onError: (Object e) {
        _flushTimer?.cancel();
        _flushTimer = null;
        _buffer.write('\n\n> ⚠️ ${formatError?.call(e) ?? e}');
        onFinish(_buffer.toString());
      },
      onDone: () {
        _flushTimer?.cancel();
        _flushTimer = null;
        onFinish(_buffer.toString());
      },
    );
  }

  /// Emits the buffer now if the throttle window elapsed, else arms a timer
  /// so the last chunk of a burst is never dropped.
  void _scheduleFlush() {
    if (_flushTimer != null) return;
    _flushTimer = Timer(updateInterval, () {
      _flushTimer = null;
      final text = _buffer.toString();
      if (text == _lastEmitted) return;
      _lastEmitted = text;
      _onUpdate?.call(text);
    });
  }

  /// Drop the subscription (aborts the request) and discard the buffer.
  void cancel() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _onUpdate = null;
    _sub?.cancel();
    _sub = null;
    _buffer.clear();
  }
}
