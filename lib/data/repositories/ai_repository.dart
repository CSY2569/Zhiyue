import 'dart:typed_data' show Uint8List;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/src/rust/api.dart' as rust;
import 'package:rbwa/src/rust/api.dart' show AiThreadCreateResult;
import 'package:rbwa/src/rust/models/ai.dart';

/// Wrapper around the FRB AI bindings (FEATURES §6, M4).
///
/// The only place the AI UI layer touches `lib/src/rust/*` directly
/// (ARCHITECTURE §1). Streaming calls return Dart `Stream<String>` -- chunk
/// events carry text, error events carry the failure message (10.4).
class AiRepository {
  /// Load the persisted BYOK config (FEATURES 6.1).
  Future<AiConfig> getAiConfig() => rust.getAiConfig();

  /// Persist the BYOK config.
  Future<int> setAiConfig(AiConfig config) => rust.setAiConfig(config: config);

  /// Streaming text action (translate / explain / search / chat, 6.2).
  /// [history] carries the thread's prior turns (6.5.2). Cancelling the
  /// returned subscription aborts the request (6.3.2).
  Stream<String> streamChat({
    required AiActionType action,
    required String text,
    required List<AiMessage> history,
  }) =>
      rust.streamChat(action: action, text: text, history: history);

  /// Streaming vision analysis of a captured region screenshot (识图,
  /// FEATURES 6.6.2 / 7.2): the PNG goes to the vision model; chunks stream
  /// back like [streamChat]. Cancelling the subscription aborts the request.
  Stream<String> streamVisionPng({required Uint8List png}) =>
      rust.streamVisionPng(png: png);

  // ---------------------------------------------------------------------------
  // Persisted conversation history (FEATURES 6.5.4)
  // ---------------------------------------------------------------------------

  /// All threads, most recently updated first.
  Future<List<AiThread>> listAiThreads() => rust.listAiThreads();

  /// One thread's messages in conversation order.
  Future<List<AiMessage>> listAiMessages(int threadId) =>
      rust.listAiMessages(threadId: threadId);

  /// Persist a new conversation window (id -1 on failure). [bookId] binds
  /// the window to a book (null = the no-book window); one window per book
  /// is enforced in the database (6.5.4).
  Future<AiThreadCreateResult> createAiThread({
    required String title,
    required AiActionType actionType,
    required int? bookId,
  }) =>
      rust.createAiThread(title: title, actionType: actionType, bookId: bookId);

  /// Append a message and bump the window's `updated_at`; [actionType] (when
  /// set) becomes the window's latest action for the history icon.
  Future<int> appendAiMessage({
    required int threadId,
    required AiRole role,
    required String content,
    AiActionType? actionType,
  }) =>
      rust.appendAiMessage(
        threadId: threadId,
        role: role,
        content: content,
        actionType: actionType,
      );

  /// Delete one conversation window (its messages cascade). Returns 1 if it
  /// existed.
  Future<int> deleteAiThread(int threadId) =>
      rust.deleteAiThread(threadId: threadId);
}

/// Riverpod provider for the singleton [AiRepository].
final aiRepositoryProvider = Provider<AiRepository>((ref) => AiRepository());
