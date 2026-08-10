import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:rbwa/src/rust/models/ai.dart';

/// One in-memory conversation window (FEATURES 6.5.4): every AI exchange
/// inside a book shares its window (one window per book, [bookId]); null
/// bookId = the no-book window.
class AiThreadState {
  AiThreadState({
    required this.id,
    required this.action,
    required this.title,
    this.dbId,
    this.bookId,
  });

  final int id;
  /// Latest action performed in this window (history-list icon).
  AiActionType action;
  /// Window title: the book title snapshot (or「未打开书籍」without one).
  final String title;
  /// The book this window belongs to; null = the no-book window.
  final int? bookId;
  /// Database row id once the window is persisted (null until then; the DB
  /// is a shadow of this in-memory state, 6.5.4).
  int? dbId;
  /// Completed turns; the in-flight assistant answer lives in
  /// [AiState.streamingText] until it finishes.
  final List<AiChatMessage> messages = [];
}

/// A single chat message (role + markdown content). Carries the originating
/// [actionType] and [createdAt] so the bubble can show "指令：翻译 · 时间".
class AiChatMessage {
  AiChatMessage({
    required this.role,
    required this.content,
    this.imagePng,
    this.imagePath,
    this.actionType,
    this.createdAt,
  });

  final AiRole role;
  final String content;

  /// Screenshot sent with a vision request (识图): in-memory PNG for the
  /// live session. When the message comes back from persisted history the
  /// PNG is gone and [imagePath] points at the stored screenshot file
  /// (absolute path, set by [listAiMessages]).
  final Uint8List? imagePng;

  /// Absolute path of the persisted screenshot (history reloads only).
  final String? imagePath;

  /// The action that originated this turn (翻译/解释/搜索/聊天/识图).
  /// Null on legacy rows or for the assistant's reply (it inherits the
  /// user turn's action, applied at the caller).
  final AiActionType? actionType;

  /// ISO-8601 timestamp from the DB (datetime('now')); null for in-memory
  /// messages not yet persisted.
  final String? createdAt;
}

/// UI state for the AI subsystem (FEATURES 6.4 / 6.5).
class AiState {
  const AiState({
    this.threads = const [],
    this.activeThreadId,
    this.streamingThreadId,
    this.streamingText = '',
    this.cardStreaming = false,
    this.cardVisible = false,
    this.cardPos = const Offset(80, 120),
    this.aiPanelOpen = false,
    this.panelCleared = false,
    this.showingThreadList = false,
  });

  final List<AiThreadState> threads;
  final int? activeThreadId;

  /// Thread whose answer is currently streaming (FEATURES 6.3.1).
  final int? streamingThreadId;
  /// Accumulated text of the in-flight answer (card + panel bubble).
  final String streamingText;

  /// Whether the card's answer is still streaming (blinking cursor + stop).
  final bool cardStreaming;

  /// Whether the floating result card is shown (FEATURES 6.4.1).
  final bool cardVisible;
  /// User-dragged card position (FEATURES 8.4).
  final Offset cardPos;

  /// Whether the AI side panel is open.
  final bool aiPanelOpen;

  /// After 「清空」 the panel stays on the empty guide (no window list) until
  /// the next AI action; the windows and messages themselves are untouched.
  final bool panelCleared;

  /// Whether the window list (对话列表) is showing. With no active thread the
  /// panel shows either this list or the empty guide: startup and 「清空」 land
  /// on the guide (history is never auto-selected), the list appears via the
  /// back button or 「查看历史对话」.
  final bool showingThreadList;

  AiThreadState? threadOf(int? id) {
    for (final t in threads) {
      if (t.id == id) return t;
    }
    return null;
  }

  AiState copyWith({
    List<AiThreadState>? threads,
    int? activeThreadId,
    bool clearActiveThread = false,
    int? streamingThreadId,
    bool clearStreaming = false,
    String? streamingText,
    bool? cardStreaming,
    bool? cardVisible,
    Offset? cardPos,
    bool? aiPanelOpen,
    bool? panelCleared,
    bool? showingThreadList,
  }) {
    return AiState(
      threads: threads ?? this.threads,
      activeThreadId: clearActiveThread
          ? null
          : (activeThreadId ?? this.activeThreadId),
      streamingThreadId:
          clearStreaming ? null : (streamingThreadId ?? this.streamingThreadId),
      streamingText: streamingText ?? this.streamingText,
      cardStreaming: cardStreaming ?? this.cardStreaming,
      cardVisible: cardVisible ?? this.cardVisible,
      cardPos: cardPos ?? this.cardPos,
      aiPanelOpen: aiPanelOpen ?? this.aiPanelOpen,
      panelCleared: panelCleared ?? this.panelCleared,
      showingThreadList: showingThreadList ?? this.showingThreadList,
    );
  }
}
