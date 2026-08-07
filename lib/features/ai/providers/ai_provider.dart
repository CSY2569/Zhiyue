import 'dart:async';
import 'dart:math' show max;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
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

/// A single chat message (role + markdown content).
class AiChatMessage {
  const AiChatMessage({
    required this.role,
    required this.content,
    this.imagePng,
  });

  final AiRole role;
  final String content;

  /// Screenshot sent with a vision request (识图). In-memory only: the
  /// persisted shadow row stores [content]; history reloads show the text.
  final Uint8List? imagePng;
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
    this.historyLoaded = false,
    this.panelCleared = false,
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

  /// Whether persisted history has been loaded (6.5.4); thread operations
  /// wait for this so in-memory ids never clash with database ids.
  final bool historyLoaded;

  /// After 「清空」 the panel stays on the empty guide (no window list) until
  /// the next AI action; the windows and messages themselves are untouched.
  final bool panelCleared;

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
    bool? historyLoaded,
    bool? panelCleared,
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
      historyLoaded: historyLoaded ?? this.historyLoaded,
      panelCleared: panelCleared ?? this.panelCleared,
    );
  }
}

/// Manages conversation windows, streaming, the result card, and the side
/// panel (FEATURES 6.2-6.6). One window per book (6.5.4): every AI exchange
/// inside a book shares its window. Windows persist to the database as a
/// shadow of the in-memory state: the UI never blocks on writes.
class AiNotifier extends Notifier<AiState> {
  int _nextThreadId = 1;
  StreamSubscription<String>? _sub;

  /// Completes once persisted history is loaded; every thread operation
  /// awaits it first (so local ids never clash with database ids).
  Completer<void> _historyReady = Completer<void>();

  /// Serializes database writes so message order is preserved.
  Future<void> _dbQueue = Future.value();

  AiRepository get _repo => ref.read(aiRepositoryProvider);

  @override
  AiState build() {
    _historyReady = Completer<void>();
    _loadHistory();
    // Stop streaming callbacks (they write state) when the element dies.
    ref.onDispose(_cancelSub);
    return const AiState();
  }

  /// Load persisted windows + messages into memory (6.5.4), then release
  /// operations. Failure degrades to a clean in-memory session.
  Future<void> _loadHistory() async {
    var loaded = <AiThreadState>[];
    var maxId = 0;
    try {
      final dbThreads = await _repo.listAiThreads();
      for (final t in dbThreads) {
        maxId = max(maxId, t.id);
        final ts = AiThreadState(
          id: t.id,
          dbId: t.id,
          action: t.actionType,
          title: t.title,
          bookId: t.bookId,
        );
        final msgs = await _repo.listAiMessages(t.id);
        ts.messages.addAll(
          msgs.map((m) => AiChatMessage(role: m.role, content: m.content)),
        );
        loaded.add(ts);
      }
      _nextThreadId = max(_nextThreadId, maxId + 1);
    } catch (_) {
      // DB read failed: keep the clean in-memory session.
    }
    if (!_historyReady.isCompleted) _historyReady.complete();
    // The provider may already be disposed by the time this lands (the page
    // unmounted mid-load): a late state write must never crash the framework.
    try {
      state = state.copyWith(
        threads: [...loaded, ...state.threads],
        historyLoaded: true,
        activeThreadId:
            state.activeThreadId ?? (loaded.isNotEmpty ? loaded.last.id : null),
      );
    } catch (_) {
      // Provider disposed; the DB is untouched and will reload next time.
    }
  }

  /// Enqueue a database write; failures are swallowed (the DB is a shadow of
  /// the in-memory state and must never block the UI).
  void _enqueue(Future<void> Function() op) {
    _dbQueue = _dbQueue.then((_) => op()).catchError((_) {});
  }

  /// The currently open book (null when the reader has no book, or outside
  /// the reader -- the no-book window).
  int? get _currentBookId => ref.read(viewerProvider).book?.id;

  /// The existing window for [bookId], if any (one window per book).
  AiThreadState? _windowOf(int? bookId) {
    for (final w in state.threads) {
      if (w.bookId == bookId) return w;
    }
    return null;
  }

  /// Window title: the book title snapshot; the no-book window is labeled
  /// 「未打开书籍」.
  String _windowTitle(int? bookId) {
    if (bookId == null) return '未打开书籍';
    final title = ref.read(viewerProvider).book?.title;
    if (title == null || title.trim().isEmpty) return '未打开书籍';
    return title;
  }

  /// Resolve the conversation window for the current book, creating it in
  /// memory when missing (persistence happens in the callers). Returns the
  /// window and whether it was just created. An existing window's latest
  /// action is refreshed for the history icon.
  (AiThreadState, bool) _resolveWindow(AiActionType action) {
    final bookId = _currentBookId;
    final existing = _windowOf(bookId);
    if (existing != null) {
      existing.action = action;
      return (existing, false);
    }
    final window = AiThreadState(
      id: _nextThreadId++,
      action: action,
      title: _windowTitle(bookId),
      bookId: bookId,
    );
    state = state.copyWith(threads: [...state.threads, window]);
    return (window, true);
  }

  /// Persist the first user message together with a new window's row;
  /// back-fills [AiThreadState.dbId].
  void _persistWindow(AiThreadState window, String firstText) {
    _enqueue(() async {
      final res = await _repo.createAiThread(
        title: window.title,
        actionType: window.action,
        bookId: window.bookId,
      );
      if (res.id <= 0) return;
      window.dbId = res.id;
      await _repo.appendAiMessage(
        threadId: res.id,
        role: AiRole.user,
        content: firstText,
        actionType: window.action,
      );
    });
  }

  /// Persist one message once the window has a database id; also refreshes
  /// the window's latest action in the shadow row.
  void _persistMessage(AiThreadState window, AiRole role, String content) {
    if (content.trim().isEmpty) return;
    _enqueue(() async {
      final dbId = window.dbId;
      if (dbId == null) return;
      await _repo.appendAiMessage(
        threadId: dbId,
        role: role,
        content: content,
        actionType: window.action,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Actions from the floating toolbar (FEATURES 6.2)
  // ---------------------------------------------------------------------------

  /// Start an action on a selection (FEATURES 6.2): routes into the current
  /// book's conversation window (creating it when it does not exist yet) and
  /// streams the answer into the result card.
  Future<void> startAction(AiActionType action, String text) async {
    await _historyReady.future;
    final (window, isNew) = _resolveWindow(action);
    window.messages.add(AiChatMessage(role: AiRole.user, content: text));
    if (isNew) {
      _persistWindow(window, text); // create + first user message
    } else {
      _persistMessage(window, AiRole.user, text);
    }
    state = state.copyWith(
      activeThreadId: window.id,
      cardVisible: true,
      cardPos: const Offset(80, 120),
      panelCleared: false,
    );
    _stream(window, action, text);
  }

  /// Multi-turn follow-up (FEATURES 6.5.2): the thread's full history is sent
  /// along. The answer streams into the result card when it is visible (the
  /// card is the conversation surface and stays open until the user closes
  /// it), and into the panel bubble otherwise.
  Future<void> sendMessage(int threadId, String text) async {
    await _historyReady.future;
    final thread = state.threadOf(threadId);
    if (thread == null) return;
    thread.messages.add(AiChatMessage(role: AiRole.user, content: text));
    state = state.copyWith(activeThreadId: threadId);
    _persistMessage(thread, AiRole.user, text);
    _stream(thread, thread.action, text);
  }

  /// Ask a question without a selection (FEATURES 6.5.1): new chat thread.
  Future<void> askQuestion(String text) =>
      startAction(AiActionType.chat, text);

  /// Region vision (识图): the captured screenshot goes into the current
  /// book's conversation window and the answer streams into the result card.
  /// The screenshot is pixel-exact (captured straight from the window's
  /// composited layer), so the model sees exactly what was selected.
  Future<void> startVision(Uint8List png) async {
    await _historyReady.future;
    final (window, isNew) = _resolveWindow(AiActionType.vision);
    window.messages.add(AiChatMessage(
      role: AiRole.user,
      content: '（区域截图）',
      imagePng: png,
    ));
    if (isNew) {
      _persistWindow(window, '（区域截图）');
    } else {
      _persistMessage(window, AiRole.user, '（区域截图）');
    }
    state = state.copyWith(
      activeThreadId: window.id,
      cardVisible: true,
      cardPos: const Offset(80, 120),
      panelCleared: false,
    );
    _streamVision(window, png);
  }

  /// Shared streaming loop: accumulates chunks into [AiState.streamingText]
  /// (card + panel bubble), then appends the finished answer to the thread.
  /// The card stays visible after completion (6.4.1) and shows the thread's
  /// full history while streaming (tail = streamingText).
  void _stream(AiThreadState thread, AiActionType action, String text) {
    final history = thread.messages
        .take(thread.messages.length - 1) // exclude the message being sent
        .map((m) => AiMessage(
              id: -1,
              threadId: thread.id,
              role: m.role,
              content: m.content,
              createdAt: '',
            ))
        .toList();
    _startStream(
      thread,
      _repo.streamChat(action: action, text: text, history: history),
    );
  }

  /// Vision request: the screenshot PNG is the input, so no text history is
  /// sent along.
  void _streamVision(AiThreadState thread, Uint8List png) {
    _startStream(thread, _repo.streamVisionPng(png: png));
  }

  void _startStream(AiThreadState thread, Stream<String> stream) {
    _cancelSub();
    final sb = StringBuffer();
    state = state.copyWith(
      streamingThreadId: thread.id,
      streamingText: '',
      // Card-streaming only when the card is the display surface
      // (selection actions); panel follow-ups stream inline instead.
      cardStreaming: state.cardVisible,
    );
    _sub = stream.listen(
      (chunk) {
        sb.write(chunk);
        state = state.copyWith(streamingText: sb.toString());
      },
      onError: (Object e) {
        // Errors (e.g. HTTP 400 with the provider message) are appended to
        // the answer text so they show up on the card AND in the panel.
        sb.write('\n\n> ⚠️ ${_errorText(e)}');
        state = state.copyWith(streamingText: sb.toString());
        _finishStream(thread, sb.toString());
      },
      onDone: () => _finishStream(thread, sb.toString()),
    );
  }

  void _finishStream(AiThreadState thread, String answer) {
    // Idempotent: an errored stream fires onError AND onDone, which would
    // otherwise append the answer twice.
    if (state.streamingThreadId != thread.id) return;
    if (answer.trim().isNotEmpty) {
      thread.messages.add(AiChatMessage(role: AiRole.assistant, content: answer));
      _persistMessage(thread, AiRole.assistant, answer);
    }
    state = state.copyWith(
      clearStreaming: true, // panel bubble -> message list
      cardStreaming: false, // card keeps showing the full answer
    );
    _sub = null;
  }

  /// Keep the in-flight partial answer in the thread (and its shadow row).
  void _keepPartialAnswer(AiThreadState? thread, String partial) {
    if (thread != null && partial.trim().isNotEmpty) {
      thread.messages.add(
        AiChatMessage(role: AiRole.assistant, content: partial),
      );
      _persistMessage(thread, AiRole.assistant, partial);
    }
  }

  /// Cancel the in-flight call (FEATURES 6.3.2): drops the FRB subscription,
  /// which aborts the Rust request. The card keeps the partial answer.
  void cancelStreaming() {
    _cancelSub();
    final thread = state.threadOf(state.streamingThreadId);
    _keepPartialAnswer(thread, state.streamingText);
    state = state.copyWith(
      clearStreaming: true,
      cardStreaming: false,
    );
  }

  void _cancelSub() {
    _sub?.cancel();
    _sub = null;
  }

  // ---------------------------------------------------------------------------
  // Result card (FEATURES 6.4)
  // ---------------------------------------------------------------------------

  /// Move the card's streaming content into the side panel thread.
  void moveCardToPanel() {
    _cancelSub();
    _keepPartialAnswer(state.threadOf(state.streamingThreadId), state.streamingText);
    state = state.copyWith(
      clearStreaming: true,
      cardStreaming: false,
      cardVisible: false,
      aiPanelOpen: true,
    );
  }

  /// Close the result card (button, FEATURES 8.6). If an answer is still
  /// streaming, its partial text is kept in the thread.
  void closeCard() {
    _cancelSub();
    _keepPartialAnswer(state.threadOf(state.streamingThreadId), state.streamingText);
    state = state.copyWith(
      clearStreaming: true,
      cardStreaming: false,
      cardVisible: false,
    );
  }

  void moveCard(Offset pos) => state = state.copyWith(cardPos: pos);

  // ---------------------------------------------------------------------------
  // Side panel (FEATURES 6.5)
  // ---------------------------------------------------------------------------

  void togglePanel() => state = state.copyWith(aiPanelOpen: !state.aiPanelOpen);

  void openThread(int threadId) =>
      state = state.copyWith(activeThreadId: threadId);

  /// Clear the current view ("清空"): leaves the conversation, stops any
  /// streaming, and hides the result card -- but the in-memory windows and
  /// the persisted messages are untouched. Deletion is a deliberate act on
  /// the 「AI 对话」 page (deleteWindow) or in the database, never here.
  Future<void> clearThreads() async {
    await _historyReady.future;
    _cancelSub();
    state = state.copyWith(
      clearActiveThread: true,
      clearStreaming: true,
      cardVisible: false,
      panelCleared: true,
    );
  }

  /// Delete one conversation window (per-window deletion, 6.5.3). Its
  /// persisted rows cascade; deleting the active window clears it (and the
  /// card showing it).
  Future<void> deleteWindow(int threadId) async {
    await _historyReady.future;
    final remaining = state.threads.where((w) => w.id != threadId).toList();
    if (remaining.length == state.threads.length) return;
    _cancelSub();
    state = state.copyWith(
      threads: remaining,
      clearActiveThread: state.activeThreadId == threadId,
      clearStreaming: state.streamingThreadId == threadId,
      cardVisible: state.activeThreadId == threadId ? false : state.cardVisible,
    );
    _enqueue(() => _repo.deleteAiThread(threadId).then((_) {}));
  }

  /// Follow the current book: select its window when one exists, otherwise
  /// clear the selection (the panel falls back to the window list / guide).
  void selectWindowForBook(int? bookId) {
    final w = _windowOf(bookId);
    state = state.copyWith(
      activeThreadId: w?.id,
      clearActiveThread: w == null,
    );
  }

  /// Back to the window list (the panel header's back button).
  void showWindowList() => state = state.copyWith(clearActiveThread: true);


  String _errorText(Object e) {
    final s = e.toString();
    return s.startsWith('Exception:') ? s.substring(10) : s;
  }
}

/// AI threads / card / streaming state.
final aiProvider = NotifierProvider<AiNotifier, AiState>(AiNotifier.new);
