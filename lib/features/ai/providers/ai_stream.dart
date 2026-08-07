import 'dart:async';

/// Wraps one streaming FRB subscription (FEATURES 6.3.1): accumulates chunks
/// into a buffer and exposes cancellation -- dropping the subscription
/// aborts the Rust request (6.3.2).
class AiStreamSession {
  StreamSubscription<String>? _sub;
  final StringBuffer _buffer = StringBuffer();

  /// Start listening to [stream]; any previous session is cancelled first.
  /// [onUpdate] fires per chunk with the accumulated text; [onFinish] fires
  /// exactly once with the final text -- also on error, where [formatError]
  /// turns the raw exception into the message shown on the card / in the
  /// panel (errors are appended to the answer so they stay visible).
  void start(
    Stream<String> stream, {
    required void Function(String text) onUpdate,
    required void Function(String text) onFinish,
    String Function(Object e)? formatError,
  }) {
    cancel();
    _sub = stream.listen(
      (chunk) {
        _buffer.write(chunk);
        onUpdate(_buffer.toString());
      },
      onError: (Object e) {
        _buffer.write('\n\n> ⚠️ ${formatError?.call(e) ?? e}');
        onFinish(_buffer.toString());
      },
      onDone: () => onFinish(_buffer.toString()),
    );
  }

  /// Drop the subscription (aborts the request) and discard the buffer.
  void cancel() {
    _sub?.cancel();
    _sub = null;
    _buffer.clear();
  }
}
