import 'package:flutter/material.dart';

/// Centered progress indicator for a full-page load.
class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.label});

  /// Optional caption under the spinner.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Inline spinner for list rows, badges and toolbar slots. Sizes follow the
/// icon ladder (16 / 20 / 24); 14 is kept for dense AI rows.
class InlineSpinner extends StatelessWidget {
  const InlineSpinner({super.key, this.size = 16, this.strokeWidth = 2});

  final double size;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(strokeWidth: strokeWidth),
    );
  }
}
