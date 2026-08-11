import 'dart:async';
import 'dart:math' show max;
import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Offset;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/providers/ai_state.dart';
import 'package:rbwa/features/ai/providers/ai_stream.dart';
import 'package:rbwa/src/rust/models/ai.dart';

/// The state model lives in [ai_state]; re-exported so consumers importing
/// this provider file keep seeing the state types.
export 'ai_state.dart';

/// Manages conversation windows, streaming, the result card, and the side
/// panel (FEATURES 6.2-6.6). One window per book (6.5.4): every AI exchange
/// inside a book shares its window.
///
/// The caller (the reader page) passes the open book's id and title snapshot
/// into each action, so this notifier never reads the reader's state.
/// Windows persist to the database as a shadow of the in-memory state: the
/// UI never blocks on writes.
class AiNotifier extends Notifier<AiState> {
  int _nextThreadId = 1;
  final AiStreamSession _session = AiStreamSession();

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
    ref.onDispose(_session.cancel);
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
          msgs.map(
            (m) => AiChatMessage(
              role: m.role,
              content: m.content,
              imagePath: m.imagePath,
              actionType: m.actionType,
              createdAt: m.createdAt,
            ),
          ),
        );
        loaded.add(ts);
      }
      // ben ruan jian you chencsy2569 kai fa ,kan dao qing hu lue zhe tiao zhu shi
      _nextThreadId = max(_nextThreadId, maxId + 1);
    } catch (_) {
      // DB read failed: keep the clean in-memory session.
    }
    if (!_historyReady.isCompleted) _historyReady.complete();
    // The provider may already be disposed by the time this lands (the page
    // unmounted mid-load): a late state write must never crash the framework.
    try {
      // History loads without selecting a window: a fresh conversation opens
      // on the empty guide, history stays one click away (对话列表).
      state = state.copyWith(threads: [...loaded, ...state.threads]);
    } catch (_) {
      // Provider disposed; the DB is untouched and will reload next time.
    }
  }

  /// Enqueue a database write; failures are swallowed (the DB is a shadow of
  /// the in-memory state and must never block the UI).
  void _enqueue(Future<void> Function() op) {
    _dbQueue = _dbQueue.then((_) => op()).catchError((_) {});
  }

  /// The existing window for [bookId], if any (one window per book).
  AiThreadState? _windowOf(int? bookId) {
    for (final w in state.threads) {
      if (w.bookId == bookId) return w;
    }
    return null;
  }

  /// Window title: the book title snapshot; the no-book window is labeled
  /// 「未打开书籍」.
  String _windowTitle(int? bookId, String? bookTitle) {
    if (bookId == null) return '未打开书籍';
    if (bookTitle == null || bookTitle.trim().isEmpty) return '未打开书籍';
    return bookTitle;
  }

  /// Resolve the conversation window for [bookId], creating it in memory when
  /// missing (persistence happens in the callers). Returns the window and
  /// whether it was just created. An existing window's latest action is
  /// refreshed for the history icon.
  (AiThreadState, bool) _resolveWindow(
    AiActionType action,
    int? bookId,
    String? bookTitle,
  ) {
    final existing = _windowOf(bookId);
    if (existing != null) {
      existing.action = action;
      return (existing, false);
    }
    final window = AiThreadState(
      id: _nextThreadId++,
      action: action,
      title: _windowTitle(bookId, bookTitle),
      bookId: bookId,
    );
    state = state.copyWith(threads: [...state.threads, window]);
    return (window, true);
  }

  /// Persist the first user message together with a new window's row;
  /// back-fills [AiThreadState.dbId]. [imagePng] is the vision screenshot
  /// of a 识图 turn, stored to disk so history can show it again.
  void _persistWindow(AiThreadState window, String firstText,
      {Uint8List? imagePng, AiActionType? action}) {
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
        imagePng: imagePng,
        actionType: action ?? window.action,
      );
    });
  }

  /// Persist one message once the window has a database id; also refreshes
  /// the window's latest action in the shadow row. [action] overrides the
  /// window's action for this message (e.g. a follow-up in a translate
  /// thread runs as chat).
  void _persistMessage(AiThreadState window, AiRole role, String content,
      {Uint8List? imagePng, AiActionType? action}) {
    if (content.trim().isEmpty) return;
    _enqueue(() async {
      final dbId = window.dbId;
      if (dbId == null) return;
      await _repo.appendAiMessage(
        threadId: dbId,
        role: role,
        content: content,
        imagePng: imagePng,
        actionType: action ?? window.action,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Actions from the floating toolbar (FEATURES 6.2)
  // ---------------------------------------------------------------------------

  /// Start an action on a selection (FEATURES 6.2): routes into [bookId]'s
  /// conversation window (creating it when it does not exist yet) and streams
  /// the answer into the result card. [bookId] / [bookTitle] snapshot the
  /// currently open book; null = the no-book window.
  Future<void> startAction(
    AiActionType action,
    String text, {
    required int? bookId,
    required String? bookTitle,
  }) =>
      _startTurn(
        action,
        text,
        bookId: bookId,
        bookTitle: bookTitle,
        startStream: (window) => _stream(window, action, text),
      );

  /// Multi-turn follow-up (FEATURES 6.5.2): the thread's full history is sent
  /// along. The answer streams into the result card when it is visible (the
  /// card is the conversation surface and stays open until the user closes
  /// it), and into the panel bubble otherwise.
  ///
  /// Follow-ups keep the thread's originating action (so an explain-thread
  /// follow-up still uses the explain system prompt). Translation threads are
  /// an exception: a follow-up there runs as chat (the user typed a question
  /// they understand, not foreign text to translate -- translate's isolated
  /// request path and `<text>` wrapping would be wrong for it).
  Future<void> sendMessage(int threadId, String text) async {
    try {
      await _historyReady.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    final thread = state.threadOf(threadId);
    if (thread == null) return;
    final action =
        thread.action == AiActionType.translate ? AiActionType.chat : thread.action;
    thread.messages.add(AiChatMessage(
      role: AiRole.user,
      content: text,
      actionType: action,
    ));
    state = state.copyWith(
      activeThreadId: threadId,
      panelCleared: false,
      showingThreadList: false,
    );
    _persistMessage(thread, AiRole.user, text, action: action);
    _stream(thread, action, text);
  }

  /// Send a typed question from any input surface (panel / card): routes to
  /// the active thread when there is one, otherwise starts a new chat thread
  /// (6.5.1). Trimming + the empty guard live here so both surfaces behave
  /// identically.
  Future<void> sendInput(
    String text, {
    required int? bookId,
    required String? bookTitle,
  }) {
    final t = text.trim();
    if (t.isEmpty) return Future.value();
    final activeId = state.activeThreadId;
    if (activeId == null) {
      return askQuestion(t, bookId: bookId, bookTitle: bookTitle);
    }
    return sendMessage(activeId, t);
  }

  /// Ask a question without a selection (FEATURES 6.5.1): new chat thread.
  Future<void> askQuestion(
    String text, {
    required int? bookId,
    required String? bookTitle,
  }) =>
      startAction(
        AiActionType.chat,
        text,
        bookId: bookId,
        bookTitle: bookTitle,
      );

  /// Region vision (识图): the captured screenshot goes into [bookId]'s
  /// conversation window and the answer streams into the result card.
  /// The screenshot is pixel-exact (captured straight from the window's
  /// composited layer), so the model sees exactly what was selected.
  Future<void> startVision(
    Uint8List png, {
    required int? bookId,
    required String? bookTitle,
  }) =>
      _startTurn(
        AiActionType.vision,
        '（区域截图）',
        imagePng: png,
        bookId: bookId,
        bookTitle: bookTitle,
        startStream: (window) => _streamVision(window, png),
      );

  /// Shared start of a new AI turn: route into [bookId]'s conversation
  /// window (creating it when it does not exist yet), persist the user
  /// message, surface the result card, and run [startStream] on the window.
  Future<void> _startTurn(
    AiActionType action,
    String text, {
    Uint8List? imagePng,
    required int? bookId,
    required String? bookTitle,
    required void Function(AiThreadState window) startStream,
  }) async {
    // Wait for persisted history to load (so local ids don't clash with DB
    // ids), but never block the user's action indefinitely: if history load
    // is slow or stuck, proceed after a short timeout (the worst case is a
    // transient id collision, which is cosmetic -- the DB row is corrected
    // on the next reload).
    try {
      await _historyReady.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Timeout: proceed without the loaded history.
    }
    final (window, isNew) = _resolveWindow(action, bookId, bookTitle);
    window.messages.add(AiChatMessage(
      role: AiRole.user,
      content: text,
      imagePng: imagePng,
      actionType: action,
    ));
    if (isNew) {
      _persistWindow(window, text, imagePng: imagePng, action: action);
    } else {
      _persistMessage(window, AiRole.user, text,
          imagePng: imagePng, action: action);
    }
    state = state.copyWith(
      activeThreadId: window.id,
      cardVisible: true,
      cardPos: const Offset(80, 120),
      panelCleared: false,
      showingThreadList: false,
    );
    startStream(window);
  }

  /// Shared streaming loop: accumulates chunks into [AiState.streamingText]
  /// (card + panel bubble), then appends the finished answer to the thread.
  /// The card stays visible after completion (6.4.1) and shows the thread's
  /// full history while streaming (tail = streamingText).
  ///
  /// Translation is an independent request: it sends an empty history so the
  /// thread's prior explain / search / chat turns never mix into the
  /// translation context (they bias the model toward explaining). The
  /// translation result is still persisted to this thread by [_finishStream],
  /// so it shows up in the conversation list like any other turn.
  void _stream(AiThreadState thread, AiActionType action, String text) {
    final history = action == AiActionType.translate
        ? <AiMessage>[] // translate: independent, no mixed context
        : thread.messages
            .take(thread.messages.length - 1) // exclude the message being sent
            .map((m) => AiMessage(
                  id: -1,
                  threadId: thread.id,
                  role: m.role,
                  content: m.content,
                  imagePath: m.imagePath,
                  actionType: m.actionType,
                  createdAt: m.createdAt ?? '',
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
    state = state.copyWith(
      streamingThreadId: thread.id,
      streamingText: '',
      // Card-streaming only when the card is the display surface
      // (selection actions); panel follow-ups stream inline instead.
      cardStreaming: state.cardVisible,
    );
    _session.start(
      stream,
      onUpdate: (text) => state = state.copyWith(streamingText: text),
      onFinish: (text) => _finishStream(thread, text),
      formatError: _errorText,
    );
  }

  void _finishStream(AiThreadState thread, String answer) {
    // Idempotent: an errored stream fires onError AND onDone, which would
    // otherwise append the answer twice.
    if (state.streamingThreadId != thread.id) return;
    if (answer.trim().isNotEmpty) {
      // The assistant reply inherits the action of the user turn that
      // triggered it (so the bubble labels both halves of the exchange).
      final action = _lastUserAction(thread);
      thread.messages.add(AiChatMessage(
        role: AiRole.assistant,
        content: answer,
        actionType: action,
      ));
      _persistMessage(thread, AiRole.assistant, answer, action: action);
    }
    state = state.copyWith(
      clearStreaming: true, // panel bubble -> message list
      cardStreaming: false, // card keeps showing the full answer
    );
  }

  /// The action type of the most recent user message in [thread] (the action
  /// that originated the current exchange), or null when none exists.
  AiActionType? _lastUserAction(AiThreadState thread) {
    for (final m in thread.messages.reversed) {
      if (m.role == AiRole.user) return m.actionType;
    }
    return null;
  }

  /// Keep the in-flight partial answer in the thread (and its shadow row).
  void _keepPartialAnswer(AiThreadState? thread, String partial) {
    if (thread != null && partial.trim().isNotEmpty) {
      final action = _lastUserAction(thread);
      thread.messages.add(
        AiChatMessage(
            role: AiRole.assistant, content: partial, actionType: action),
      );
      _persistMessage(thread, AiRole.assistant, partial, action: action);
    }
  }

  // ---------------------------------------------------------------------------
  // Result card (FEATURES 6.4)
  // ---------------------------------------------------------------------------

  /// Shared tail of the card-teardown actions: keep the partial answer in
  /// the thread, then drop the in-flight stream and clear the streaming
  /// flags. [hideCard] hides the result card (close / expand); the stop
  /// button keeps it visible with the partial answer (6.3.2). [openPanel]
  /// (the expand action) additionally opens the side panel.
  void _endStream({bool hideCard = false, bool openPanel = false}) {
    _keepPartialAnswer(state.threadOf(state.streamingThreadId), state.streamingText);
    _session.cancel();
    state = state.copyWith(
      clearStreaming: true,
      cardStreaming: false,
      cardVisible: (hideCard || openPanel) ? false : null,
      aiPanelOpen: openPanel ? true : null,
    );
  }

  /// Cancel the in-flight call (FEATURES 6.3.2): drops the FRB subscription,
  /// which aborts the Rust request. The card keeps the partial answer.
  void cancelStreaming() => _endStream();

  /// Move the card's streaming content into the side panel thread.
  void moveCardToPanel() => _endStream(openPanel: true);

  /// Close the result card (button, FEATURES 8.6). If an answer is still
  /// streaming, its partial text is kept in the thread.
  void closeCard() => _endStream(hideCard: true);

  /// Move the card by [delta] (accumulated against the live state, not a
  /// stale build-time snapshot -- multiple pan events within one frame each
  /// read the current position, so the card tracks the pointer exactly).
  void moveCard(Offset delta) =>
      state = state.copyWith(cardPos: state.cardPos + delta);

  // ---------------------------------------------------------------------------
  // Side panel (FEATURES 6.5)
  // ---------------------------------------------------------------------------

  void togglePanel() => state = state.copyWith(aiPanelOpen: !state.aiPanelOpen);

  void openThread(int threadId) => state = state.copyWith(
        activeThreadId: threadId,
        showingThreadList: false,
      );

  /// Clear the current view ("清空"): leaves the conversation, stops any
  /// streaming, and hides the result card -- but the in-memory windows and
  /// the persisted messages are untouched. Deletion is a deliberate act on
  /// the 「AI 对话」 page (deleteWindow) or in the database, never here.
  Future<void> clearThreads() async {
    try {
      await _historyReady.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    _session.cancel();
    state = state.copyWith(
      clearActiveThread: true,
      clearStreaming: true,
      cardVisible: false,
      panelCleared: true,
      showingThreadList: false,
    );
  }

  /// Delete one conversation window (per-window deletion, 6.5.3). Its
  /// persisted rows cascade; deleting the active window clears it (and the
  /// card showing it).
  Future<void> deleteWindow(int threadId) async {
    try {
      await _historyReady.future.timeout(const Duration(seconds: 2));
    } catch (_) {}
    final remaining = state.threads.where((w) => w.id != threadId).toList();
    if (remaining.length == state.threads.length) return;
    _session.cancel();
    state = state.copyWith(
      threads: remaining,
      clearActiveThread: state.activeThreadId == threadId,
      clearStreaming: state.streamingThreadId == threadId,
      cardVisible: state.activeThreadId == threadId ? false : state.cardVisible,
      // Deleting the active window lands back on the window list.
      showingThreadList: state.activeThreadId == threadId,
    );
    _enqueue(() => _repo.deleteAiThread(threadId).then((_) {}));
  }

  /// Follow the current book: select its window when one exists, otherwise
  /// clear the selection (the panel falls back to the empty guide; history
  /// stays reachable through 对话列表).
  void selectWindowForBook(int? bookId) {
    final w = _windowOf(bookId);
    state = state.copyWith(
      activeThreadId: w?.id,
      clearActiveThread: w == null,
      showingThreadList: false,
    );
  }

  /// Back to the window list (the panel header's back button).
  void showWindowList() => state = state.copyWith(
        clearActiveThread: true,
        showingThreadList: true,
      );

  String _errorText(Object e) {
    final s = e.toString();
    return s.startsWith('Exception:') ? s.substring(10) : s;
  }
}

/// AI threads / card / streaming state.
final aiProvider = NotifierProvider<AiNotifier, AiState>(AiNotifier.new);
