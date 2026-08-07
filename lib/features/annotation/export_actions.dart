import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/features/annotation/providers/annotation_provider.dart';

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
