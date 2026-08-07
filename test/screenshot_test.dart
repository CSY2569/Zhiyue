import 'dart:io' show Directory, File;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/features/ai/providers/ai_provider.dart';
import 'package:rbwa/features/ai/widgets/result_card.dart';
import 'package:rbwa/features/screenshot/free_screenshot_overlay.dart';
import 'package:rbwa/features/screenshot/screenshot_provider.dart';
import 'package:rbwa/src/rust/api.dart' show AiThreadCreateResult;
import 'package:rbwa/src/rust/models/ai.dart';

const _red = Color(0xFFE53935);
const _redArgb = 0xFFE53935;

/// Fake AI repository: no Rust; the vision stream answers with fixed chunks
/// and threads persist in memory (mirrors the FRB surface).
class _FakeAiRepo extends AiRepository {
  final visionCalls = <Uint8List>[];
  final savedThreads = <int, String>{};
  final savedMessages = <int, List<AiChatMessage>>{};
  int _nextThreadId = 1;

  @override
  Future<List<AiThread>> listAiThreads() async => [];

  @override
  Future<List<AiMessage>> listAiMessages(int threadId) async => [];

  @override
  Future<AiThreadCreateResult> createAiThread({
    required String title,
    required AiActionType actionType,
    required int? bookId,
  }) async {
    final id = _nextThreadId++;
    savedThreads[id] = title;
    savedMessages[id] = [];
    return AiThreadCreateResult(id: id, error: null);
  }

  @override
  Future<int> appendAiMessage({
    required int threadId,
    required AiRole role,
    required String content,
    AiActionType? actionType,
  }) async {
    savedMessages[threadId]?.add(AiChatMessage(role: role, content: content));
    return 1;
  }

  @override
  Future<int> clearAiThreads() async {
    savedThreads.clear();
    savedMessages.clear();
    return 1;
  }

  @override
  Stream<String> streamVisionPng({required Uint8List png}) {
    visionCalls.add(png);
    return Stream.fromIterable(['识别', '结果']);
  }
}

/// Harness: a red box in a known window region + a button that enters
/// screenshot mode (mirrors the reader toolbar 识图 entry).
class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const Positioned(
              left: 40,
              top: 40,
              width: 200,
              height: 120,
              child: ColoredBox(color: _red),
            ),
            // The result card is where the vision answer streams in (as in
            // the reader page).
            const ResultCard(),
            Align(
              alignment: Alignment.topRight,
              child: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () {
                    final overlay = Overlay.of(context, rootOverlay: true);
                    ref.read(screenshotProvider.notifier).begin(overlay);
                  },
                  child: const Text('识图'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  late Directory tmpDir;
  late _FakeAiRepo repo;

  setUp(() async {
    // Screenshots land in an isolated temp dir -- never the user's disk.
    tmpDir = await Directory.systemTemp.createTemp('rbwa_shot_');
    repo = _FakeAiRepo();
  });

  tearDown(() async {
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpHarness(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenshotOutputDirProvider.overrideWithValue(tmpDir),
          aiRepositoryProvider.overrideWithValue(repo),
        ],
        child: const _Harness(),
      ),
    );
  }

  ProviderContainer container(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(_Harness)));

  /// Drag a selection over the red box and poll until the vision stream has
  /// finished (real-async polling window: rasterization + PNG encode + file
  /// IO are engine/IO futures (complete during runAsync), but their
  /// continuations are scheduled in the fake zone, so each iteration pumps).
  Future<void> dragAndWaitVision(
    WidgetTester tester, {
    Offset from = const Offset(50, 50),
    Offset to = const Offset(220, 150),
  }) async {
    final gesture = await tester.startGesture(from);
    await gesture.moveTo(to);
    await gesture.up();
    // Render the (transparent) capturing frame so the layer is clean.
    await tester.pump();

    await tester.runAsync(() async {
      for (var i = 0; i < 300; i++) {
        final s = container(tester).read(aiProvider);
        if (s.streamingThreadId == null &&
            s.threads.isNotEmpty &&
            s.threads.first.messages.length >= 2) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  testWidgets('识图: 选区截出的像素直达识图模型，答案出现在卡片', (tester) async {
    await pumpHarness(tester);
    final dpr = tester.view.devicePixelRatio;

    // Enter screenshot mode: full-window overlay with the drag hint.
    await tester.tap(find.text('识图'));
    await tester.pump();
    expect(find.byType(FreeScreenshotOverlay), findsOneWidget);

    // Drag a 170x100 logical region fully inside the red box.
    await dragAndWaitVision(tester);

    // Screenshot mode ended; the capture went straight to the vision model.
    final shot = container(tester).read(screenshotProvider);
    expect(shot.phase, ScreenshotPhase.idle);
    expect(find.byType(FreeScreenshotOverlay), findsNothing);
    expect(repo.visionCalls, hasLength(1));

    // A vision thread was created; the result card shows the streamed answer.
    final state = container(tester).read(aiProvider);
    expect(state.cardVisible, isTrue);
    final thread = state.threadOf(state.activeThreadId)!;
    expect(thread.action, AiActionType.vision);
    expect(thread.bookId, isNull); // harness has no book -> the no-book window
    expect(thread.title, '未打开书籍');
    expect(thread.messages.first.content, '（区域截图）');
    expect(thread.messages.last.role, AiRole.assistant);
    expect(thread.messages.last.content, '识别结果');
    expect(find.textContaining('识别结果'), findsOneWidget);

    // The captured PNG (kept on the vision user message) is pixel-exact:
    // dimensions = selection x device pixel ratio, sampled pixels all red.
    final png = thread.messages.first.imagePng!;
    late ui.Image img;
    late ByteData raw;
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(png);
      final frame = await codec.getNextFrame();
      img = frame.image;
      raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      codec.dispose();
    });
    expect(img.width, (170 * dpr).round());
    expect(img.height, (100 * dpr).round());
    final bytes = raw.buffer.asUint8List();
    bool isRed(int x, int y) {
      final i = (y * img.width + x) * 4;
      return (bytes[i] << 16 | bytes[i + 1] << 8 | bytes[i + 2]) ==
          (_redArgb & 0xFFFFFF);
    }

    expect(isRed(img.width ~/ 2, img.height ~/ 2), isTrue);
    expect(isRed(2, 2), isTrue);
    expect(isRed(img.width - 3, img.height - 3), isTrue);
    img.dispose();

    // The screenshot is also saved to the isolated output dir.
    expect(tmpDir.listSync(), hasLength(1));

    // Thread persisted (shadow DB): user + assistant rows.
    expect(repo.savedMessages.values.first, hasLength(2));
  });

  testWidgets('Esc 取消识图并移除遮罩', (tester) async {
    await pumpHarness(tester);
    await tester.tap(find.text('识图'));
    await tester.pump();
    expect(find.byType(FreeScreenshotOverlay), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(
      container(tester).read(screenshotProvider).phase,
      ScreenshotPhase.idle,
    );
    expect(find.byType(FreeScreenshotOverlay), findsNothing);
    expect(repo.visionCalls, isEmpty);
  });

  testWidgets('点击（无拖拽）视为取消', (tester) async {
    await pumpHarness(tester);
    await tester.tap(find.text('识图'));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(300, 300));
    await gesture.up();
    await tester.pump();

    expect(
      container(tester).read(screenshotProvider).phase,
      ScreenshotPhase.idle,
    );
    expect(find.byType(FreeScreenshotOverlay), findsNothing);
  });

  testWidgets('右键取消识图', (tester) async {
    await pumpHarness(tester);
    await tester.tap(find.text('识图'));
    await tester.pump();

    final gesture = await tester.startGesture(
      const Offset(300, 300),
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();

    expect(
      container(tester).read(screenshotProvider).phase,
      ScreenshotPhase.idle,
    );
  });

  testWidgets('截图落盘到隔离目录且文件名含像素尺寸', (tester) async {
    await pumpHarness(tester);
    await tester.tap(find.text('识图'));
    await tester.pump();

    await dragAndWaitVision(
      tester,
      from: const Offset(100, 100),
      to: const Offset(200, 150),
    );

    // Saved with the captured pixel dimensions in the name.
    final files = tmpDir.listSync();
    expect(files, hasLength(1));
    final name = (files.single as File).uri.pathSegments.last;
    expect(name, matches(RegExp(r'^rbwa_\d{8}_\d{6}_\d+x\d+\.png$')));

    // Vision fired and the overlay closed (no preview card remains).
    expect(repo.visionCalls, hasLength(1));
    expect(
      container(tester).read(screenshotProvider).phase,
      ScreenshotPhase.idle,
    );
    expect(find.text('关闭'), findsNothing);
  });
}
