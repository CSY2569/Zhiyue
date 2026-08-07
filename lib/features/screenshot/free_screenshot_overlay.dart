import 'package:flutter/gestures.dart' show kPrimaryMouseButton, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, LogicalKeyboardKey, SystemMouseCursors;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screenshot_provider.dart';

/// Full-window overlay for free screenshots (所选即所得): a dim mask with a
/// cut-out for the drag selection, then a preview card with the captured
/// image once the capture completes. The overlay spans the whole window, so
/// its local coordinates are the window coordinates used for the capture.
class FreeScreenshotOverlay extends ConsumerStatefulWidget {
  const FreeScreenshotOverlay({super.key});

  @override
  ConsumerState<FreeScreenshotOverlay> createState() =>
      _FreeScreenshotOverlayState();
}

class _FreeScreenshotOverlayState extends ConsumerState<FreeScreenshotOverlay> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'screenshot-overlay');

  @override
  void initState() {
    super.initState();
    // Take keyboard focus so Esc always cancels, regardless of what had
    // focus when screenshot mode started.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(screenshotProvider);
    final notifier = ref.read(screenshotProvider.notifier);
    final theme = Theme.of(context);

    final selecting = state.phase == ScreenshotPhase.selecting;
    final previewing = state.phase == ScreenshotPhase.preview;

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          notifier.cancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: previewing
            ? SystemMouseCursors.basic
            : SystemMouseCursors.precise,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            // Read fresh state: the widget may not have rebuilt since the
            // last drag update.
            final st = ref.read(screenshotProvider);
            if (st.phase != ScreenshotPhase.selecting) return;
            if (e.buttons & kSecondaryMouseButton != 0) {
              notifier.cancel();
            } else if (e.buttons & kPrimaryMouseButton != 0) {
              notifier.updateDrag(e.localPosition, e.localPosition);
            }
          },
          onPointerMove: (e) {
            final st = ref.read(screenshotProvider);
            if (st.phase != ScreenshotPhase.selecting || st.start == null) {
              return;
            }
            if (e.buttons & kPrimaryMouseButton != 0) {
              notifier.updateDrag(st.start!, e.localPosition);
            }
          },
          onPointerUp: (e) {
            final st = ref.read(screenshotProvider);
            if (st.phase == ScreenshotPhase.selecting) {
              notifier.finishDrag(e.localPosition);
            }
          },
          onPointerCancel: (_) {
            final st = ref.read(screenshotProvider);
            if (st.phase == ScreenshotPhase.selecting) notifier.cancel();
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (selecting)
                CustomPaint(
                  painter: _MaskPainter(
                    selection: state.selection,
                    dimColor: Colors.black.withValues(alpha: 0.45),
                    accentColor: theme.colorScheme.primary,
                  ),
                ),
              if (previewing)
                _PreviewCard(state: state, notifier: notifier),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dim mask with a cut-out for the selection, the selection border, and the
/// hint / size labels. Paints nothing once the capture starts, so the
/// captured frame is the clean app underneath.
class _MaskPainter extends CustomPainter {
  _MaskPainter({
    required this.selection,
    required this.dimColor,
    required this.accentColor,
  });

  final Rect? selection;
  final Color dimColor;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final full = Offset.zero & size;
    final sel = selection;
    if (sel == null || sel.isEmpty) {
      canvas.drawRect(full, Paint()..color = dimColor);
      _paintHint(canvas, size);
      return;
    }
    final hole = Path.combine(
      PathOperation.difference,
      Path()..addRect(full),
      Path()..addRect(sel),
    );
    canvas.drawPath(hole, Paint()..color = dimColor);
    // Contrast border: white ring outside, accent ring inside.
    canvas.drawRect(
      sel.inflate(1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = Colors.white,
    );
    canvas.drawRect(
      sel,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = accentColor,
    );
    _paintSizeLabel(canvas, size, sel);
  }

  void _paintHint(Canvas canvas, Size size) {
    const text = '拖动选择截图区域 · Esc / 右键取消';
    final tp = TextPainter(
      text: const TextSpan(
        text: text,
        style: TextStyle(color: Colors.white, fontSize: 13),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromLTWH(
      size.width / 2 - tp.width / 2 - 12,
      20,
      tp.width + 24,
      tp.height + 12,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(6)),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    tp.paint(canvas, Offset(rect.left + 12, rect.top + 6));
  }

  void _paintSizeLabel(Canvas canvas, Size size, Rect sel) {
    final label = '${sel.width.round()} × ${sel.height.round()} px';
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = sel.right - tp.width - 4;
    var dy = sel.bottom + 8;
    if (dy + tp.height + 8 > size.height) dy = sel.top - tp.height - 8;
    if (dx < 4) dx = 4;
    final rect = Rect.fromLTWH(dx, dy, tp.width + 8, tp.height + 6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      Paint()..color = Colors.black.withValues(alpha: 0.55),
    );
    tp.paint(canvas, Offset(dx + 4, dy + 3));
  }

  @override
  bool shouldRepaint(_MaskPainter oldDelegate) =>
      oldDelegate.selection != selection ||
      oldDelegate.dimColor != dimColor ||
      oldDelegate.accentColor != accentColor;
}

/// Result card, shown only when the capture failed: the error message plus
/// 重新截图 / 关闭. On success the overlay closes and the captured pixels go
/// straight to the vision model (识图).
class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.state, required this.notifier});

  final ScreenshotState state;
  final ScreenshotNotifier notifier;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.35),
      child: Center(
        child: Material(
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 6,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 20,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text('截图失败', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.error ?? '未知错误',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.error),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: notifier.restart,
                        child: const Text('重新截图'),
                      ),
                      FilledButton(
                        onPressed: notifier.cancel,
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
