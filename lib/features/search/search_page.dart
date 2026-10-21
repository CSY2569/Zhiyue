import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/core/widgets/empty_state.dart';
import 'package:rbwa/core/widgets/loading_state.dart';
import 'package:rbwa/core/widgets/search_field.dart';
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
  /// null = no search performed yet; otherwise the last result.
  List<SearchHit>? _hits;
  String? _error;
  bool _loading = false;

  /// The debounced query that produced [_hits] (used by the empty state and
  /// the result rows so they never read a controller mid-animation).
  String _query = '';

  /// Monotonic request id: a slow query must never overwrite the results of a
  /// newer one (typing "量子" then "量子计算" can otherwise land out of order
  /// and show hits for text no longer in the field).
  int _requestSeq = 0;

  Future<void> _run(String raw) async {
    final query = raw.trim();
    final seq = ++_requestSeq;
    if (query.isEmpty) {
      setState(() {
        _query = '';
        _hits = null;
        _error = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ref.read(searchRepositoryProvider).searchBooks(query);
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _query = query;
        _hits = res.error == null ? res.hits : null;
        _error = res.error;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _requestSeq) return;
      setState(() {
        _query = query;
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
    context.push('/reader/${hit.bookId}');
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
              child: DebouncedSearchField(
                hint: '搜索全文…（文字版 PDF 与已扫描页面）',
                autofocus: true,
                onChanged: _run,
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
      return const LoadingState();
    }
    if (_error != null) {
      return EmptyState(
        icon: LucideIcons.circleAlert,
        title: '搜索失败',
        message: _error,
      );
    }
    final hits = _hits;
    if (hits == null) {
      return const EmptyState(
        icon: LucideIcons.search,
        title: '全文搜索',
        message: '输入关键词，搜索所有书籍的文字版页面\n与已扫描（OCR）页面的内容',
      );
    }
    if (hits.isEmpty) {
      return EmptyState(
        icon: LucideIcons.searchX,
        title: '没有找到结果',
        message: '没有内容包含「$_query」\n'
            '未扫描的扫描版页面与图片书不参与搜索',
      );
    }
    return _ResultsList(hits: hits, query: _query, onOpen: _openHit);
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
    final books = ref.watch(libraryBooksProvider).valueOrNull ?? const [];
    // One lookup map instead of a linear scan per result group.
    final titles = {for (final b in books) b.id: b.title};

    // Group preserving book order (hits are sorted by book then page), then
    // flatten to a lazy list: a query can return up to 200 hits, and building
    // every rich-text row in one pass stalled the first frame after a search.
    final groups = <int, List<SearchHit>>{};
    for (final h in hits) {
      groups.putIfAbsent(h.bookId, () => []).add(h);
    }
    final rows = <Object>[];
    for (final entry in groups.entries) {
      rows.add(entry.key);
      rows.addAll(entry.value);
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '仅索引文字版页面与已扫描页面；图片书与未扫描页不在搜索结果中',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          );
        }
        final row = rows[index];
        if (row is int) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              titles[row] ?? '书籍 #$row',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          );
        }
        final hit = row as SearchHit;
        return ListTile(
          dense: true,
          leading: const Icon(LucideIcons.fileText, size: 20),
          title: Text('第 ${hit.page + 1} 页', style: theme.textTheme.bodySmall),
          subtitle: _SnippetText(snippet: hit.snippet, query: query),
          onTap: () => onOpen(hit, query),
        );
      },
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
    final base = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
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
      spans.add(
        TextSpan(
          text: snippet.substring(idx, idx + q.length),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
      from = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}
