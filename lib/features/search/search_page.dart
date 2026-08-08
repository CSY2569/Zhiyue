import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/data/repositories/search_repository.dart';
import 'package:rbwa/features/library/providers/library_providers.dart';
import 'package:rbwa/features/search/providers/search_providers.dart';
import 'package:rbwa/src/rust/api.dart' show SearchHit;

/// 全文搜索 page (FEATURES 3.5.2, M6): library-wide search over indexed
/// pages (text-layer PDFs + OCR-scanned pages). Results group by book;
/// tapping a hit opens the reader on that page with the hit words
/// highlighted (3.5.3).
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  /// null = no search performed yet; otherwise the last result.
  List<SearchHit>? _hits;
  String? _error;
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    // Same 300ms debounce as the title search (FEATURES 2.7).
    _debounce = Timer(const Duration(milliseconds: 300), () => _run(value));
  }

  Future<void> _run(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) {
      setState(() {
        _hits = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final res =
          await ref.read(searchRepositoryProvider).searchBooks(query);
      if (!mounted) return;
      setState(() {
        _hits = res.error == null ? res.hits : null;
        _error = res.error;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hits = null;
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openHit(SearchHit hit, String query) {
    // Carry the jump target: the reader opens on this page (0-indexed ->
    // 1-indexed) and the hit-highlight layer marks the query.
    ref.read(searchHitProvider.notifier).state = SearchHitTarget(
      bookId: hit.bookId,
      page: hit.page,
      query: query,
    );
    context.go('/reader/${hit.bookId}');
  }

  @override
  Widget build(BuildContext context) {
    // Own Scaffold: the shell route only wraps pages in the title bar, so
    // the page itself must provide the Material context (like the library
    // and settings pages do).
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: TextField(
                controller: _controller,
                focusNode: _focus,
                autofocus: true,
                onChanged: _onChanged,
                decoration: InputDecoration(
                  hintText: '搜索全文…（文字版 PDF 与已扫描页面）',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: '清空',
                          visualDensity: VisualDensity.compact,
                          onPressed: () {
                            _controller.clear();
                            _onChanged('');
                          },
                        ),
                ),
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: '搜索失败',
        message: _error,
      );
    }
    final hits = _hits;
    if (hits == null) {
      return const EmptyState(
        icon: Icons.search,
        title: '全文搜索',
        message: '输入关键词，搜索所有书籍的文字版页面\n与已扫描（OCR）页面的内容',
      );
    }
    if (hits.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: '没有找到结果',
        message: '没有内容包含「${_controller.text.trim()}」\n'
            '未扫描的扫描版页面与图片书不参与搜索',
      );
    }
    return _ResultsList(
      hits: hits,
      query: _controller.text.trim(),
      onOpen: _openHit,
    );
  }
}

/// Results grouped by book (book header + one row per hit page).
class _ResultsList extends ConsumerWidget {
  const _ResultsList({
    required this.hits,
    required this.query,
    required this.onOpen,
  });

  final List<SearchHit> hits;
  final String query;
  final void Function(SearchHit hit, String query) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final books = ref.watch(libraryBooksProvider).valueOrNull ??
        const [];
    String titleOf(int bookId) => books
        .where((b) => b.id == bookId)
        .map((b) => b.title)
        .firstOrNull ??
        '书籍 #$bookId';

    // Group preserving book order (hits are sorted by book then page).
    final groups = <int, List<SearchHit>>{};
    for (final h in hits) {
      groups.putIfAbsent(h.bookId, () => []).add(h);
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        for (final entry in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              titleOf(entry.key),
              style: theme.textTheme.titleSmall
                  ?.copyWith(color: theme.colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          for (final hit in entry.value)
            ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined, size: 18),
              title: Text(
                '第 ${hit.page + 1} 页',
                style: theme.textTheme.bodySmall,
              ),
              subtitle: _SnippetText(snippet: hit.snippet, query: query),
              onTap: () => onOpen(hit, query),
            ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '仅索引文字版页面与已扫描页面；图片书与未扫描页不在搜索结果中',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }
}

/// Snippet with every occurrence of [query] bolded.
class _SnippetText extends StatelessWidget {
  const _SnippetText({required this.snippet, required this.query});

  final String snippet;
  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final q = query.toLowerCase();
    final lower = snippet.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final idx = lower.indexOf(q, from);
      if (idx < 0) {
        spans.add(TextSpan(text: snippet.substring(from)));
        break;
      }
      if (idx > from) {
        spans.add(TextSpan(text: snippet.substring(from, idx)));
      }
      spans.add(TextSpan(
        text: snippet.substring(idx, idx + q.length),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ));
      from = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
