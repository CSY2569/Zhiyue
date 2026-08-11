import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

// 本软件由IceFish开发，看到请忽略这条注释
import 'package:rbwa/features/ai/pages/ai_conversations_page.dart';
import 'package:rbwa/features/library/library_page.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/reader_page.dart';
import 'package:rbwa/features/search/search_page.dart';
import 'package:rbwa/features/settings/settings_page.dart';
import 'package:rbwa/features/shell/app_title_bar.dart';

/// Application routes (FEATURES §2/3 + §8.1 navigation).
///
/// A [ShellRoute] hosts the frameless title bar around all top-level
/// destinations (library / reader / AI conversations / settings). Because
/// the shell builder runs inside the Router's Navigator on every
/// navigation, it always reflects the current route: the reader shows the
/// book title and a back button, other routes show the app name
/// (FEATURES 8.1 "居中显示当前书名").
final appRouter = GoRouter(
  initialLocation: '/library',
  routes: [
    ShellRoute(
      builder: (context, state, child) {
        final isReader = state.matchedLocation.startsWith('/reader');
        final isAiChat = state.matchedLocation.startsWith('/ai-chat');
        final isSearch = state.matchedLocation.startsWith('/search');
        return Column(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final bookTitle = isReader
                    ? ref.watch(viewerProvider).book?.title
                    : null;
                final title = bookTitle ??
                    (isReader
                        ? '阅读器'
                        : isAiChat
                            ? 'AI 对话'
                            : isSearch
                                ? '全文搜索'
                                : '智阅');
                return AppTitleBar(
                  title: title,
                  showBack: isReader || isAiChat || isSearch,
                );
              },
            ),
            Expanded(child: child),
          ],
        );
      },
      routes: [
        GoRoute(
          path: '/library',
          name: 'library',
          builder: (context, state) => const LibraryPage(),
        ),
        GoRoute(
          path: '/reader/:bookId',
          name: 'reader',
          builder: (context, state) {
            final id = int.tryParse(state.pathParameters['bookId'] ?? '') ?? 0;
            return ReaderPage(bookId: id);
          },
        ),
        GoRoute(
          path: '/ai-chat',
          name: 'ai-chat',
          builder: (context, state) => const AiConversationsPage(),
        ),
        GoRoute(
          path: '/search',
          name: 'search',
          builder: (context, state) => const SearchPage(),
        ),
        GoRoute(
          path: '/settings',
          name: 'settings',
          builder: (context, state) => const SettingsPage(),
        ),
      ],
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(child: Text('Route not found: ${state.uri}')),
  ),
);
