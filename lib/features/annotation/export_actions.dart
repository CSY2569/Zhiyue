import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/models/image_mark.dart';
import 'package:rbwa/features/annotation/providers/annotation_provider.dart';
import 'package:rbwa/features/annotation/providers/image_mark_provider.dart';
import 'package:rbwa/features/annotation/widgets/image_mark_layer.dart'
    show paintMark;
import 'package:rbwa/data/repositories/reader_repository.dart';
import 'package:rbwa/features/reader/providers/image_decoder.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';

/// Format of the last export, so Ctrl+S repeats it (FLUTTER_UI_MIGRATION
/// 8.x: "Ctrl+S -> export annotations (last used format)").
String? _lastExportFormat;

/// Export the open book's annotations via a save-file dialog (FEATURES
/// 4.5.1). Shared by the sidebar buttons and the Ctrl+S shortcut. Returns
/// after the dialog closes; shows a SnackBar on success/failure.
Future<void> exportAnnotations(
  BuildContext context,
  WidgetRef ref, {
  String? format, // 'markdown' | 'json'; null = last used (default markdown)
}) async {
  final fmt = format ?? _lastExportFormat ?? 'markdown';
  final notifier = ref.read(annotationProvider.notifier);
  // Grab the messenger before the await (no context use across async gaps).
  final messenger = ScaffoldMessenger.of(context);
  final content = fmt == 'markdown'
      ? await notifier.exportMarkdown()
      : await notifier.exportJson();

  if (content == null) {
    messenger.showSnackBar(const SnackBar(content: Text('导出失败')));
    return;
  }

  final isMarkdown = fmt == 'markdown';
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出阅读标注',
    fileName: isMarkdown ? '阅读标注.md' : '阅读标注.json',
    type: FileType.custom,
    allowedExtensions: [isMarkdown ? 'md' : 'json'],
    // file_picker writes `bytes` to the chosen path for us.
    bytes: Uint8List.fromList(utf8.encode(content)),
  );
  if (path == null) return; // user cancelled
  _lastExportFormat = fmt;
  messenger.showSnackBar(SnackBar(content: Text('已导出到 $path')));
}

/// Export the current page with its image-layer marks merged into the bitmap
/// (FEATURES 5.6): the page renders at original resolution, the marks redraw
/// on top via the same painter as the live layer (so the output matches the
/// screen), and the result saves as PNG. Non-merged exports (mark data JSON)
/// go through [exportAnnotations].
Future<void> exportMergedImage(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final state = ref.read(viewerProvider);
  final book = state.book;
  if (book == null) return;
  final page = state.currentPage - 1; // 0-indexed
  final repo = ref.read(readerRepositoryProvider);

  // 1. Original-resolution page bitmap (7.1.8-style source, not the
  // on-screen zoom).
  final result = await repo.renderPage(book.id, page, 1.0, 1.0);
  if (result.error != null || result.rgba.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('渲染页面失败')));
    return;
  }
  final image =
      await decodeRgbaImage(result.width, result.height, result.rgba);
  if (image == null) {
    messenger.showSnackBar(const SnackBar(content: Text('解码页面失败')));
    return;
  }

  // 2. Load stamp images referenced by this page's marks.
  final marks = [
    for (final m in ref.read(imageMarkProvider).valueOrNull ?? const [])
      if (m.page == page) m,
  ];
  final stampImages = <String, ui.Image>{};
  for (final m in marks) {
    final file = m.stampFile;
    if (m.kind == ImageMarkKind.stamp && file != null) {
      try {
        stampImages[file] =
            await decodeImageFromList(await File(file).readAsBytes());
      } catch (_) {
        // Missing stamp file: the mark paints its placeholder outline.
      }
    }
  }

  // 3. Redraw page + marks through the shared painter.
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final size = Size(image.width.toDouble(), image.height.toDouble());
  canvas.drawImage(image, Offset.zero, Paint());
  for (final m in marks) {
    paintMark(canvas, size, m, stampImage: stampImages[m.stampFile]);
  }
  final picture = recorder.endRecording();
  final merged = await picture.toImage(image.width, image.height);
  picture.dispose();
  image.dispose();
  for (final img in stampImages.values) {
    img.dispose();
  }

  // 4. PNG bytes -> save dialog.
  final data = await merged.toByteData(format: ui.ImageByteFormat.png);
  merged.dispose();
  if (data == null) {
    messenger.showSnackBar(const SnackBar(content: Text('编码图片失败')));
    return;
  }
  final path = await FilePicker.platform.saveFile(
    dialogTitle: '导出拼合图片',
    fileName: '${book.title}_p${page + 1}.png',
    type: FileType.image,
    bytes: data.buffer.asUint8List(),
  );
  if (path == null) return; // user cancelled
  messenger.showSnackBar(SnackBar(content: Text('已导出到 $path')));
}
