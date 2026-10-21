import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/ai/pages/ai_conversations_page.dart';
import 'package:rbwa/features/library/library_page.dart';
import 'package:rbwa/features/reader/providers/viewer_provider.dart';
import 'package:rbwa/features/reader/reader_page.dart';
import 'package:rbwa/features/search/search_page.dart';
import 'package:rbwa/features/settings/settings_page.dart';
import 'package:rbwa/features/shell/app_title_bar.dart';

/// Which top-level destination the shell is currently wrapping.
///
/// Derived from the navigation URI, not `GoRouterState.matchedLocation`: the
/// shell route carries no path of its own, so its `matchedLocation` stays at
/// the parent prefix ('/') and can never distinguish the child page. That
/// made the title bar always read 智阅 and hid the back button, leaving
/// desktop users with no in-app way out of the reader.
enum ShellDestination { library, reader, aiChat, search, settings }

ShellDestination shellDestinationFor(String location) {
  if (location.startsWith('/reader')) return ShellDestination.reader;
  if (location.startsWith('/ai-chat')) return ShellDestination.aiChat;
  if (location.startsWith('/search')) return ShellDestination.search;
  if (location.startsWith('/settings')) return ShellDestination.settings;
  return ShellDestination.library;
}

/// Title-bar text and back affordance for [location].
({String title, bool showBack}) titleBarInfoFor(
  String location, {
  String? bookTitle,
}) {
  final destination = shellDestinationFor(location);
  final trimmedTitle = bookTitle?.trim();
  final title = switch (destination) {
    ShellDestination.reader => (trimmedTitle == null || trimmedTitle.isEmpty)
        ? '阅读器'
        : trimmedTitle,
    ShellDestination.aiChat => 'AI 对话',
    ShellDestination.search => '全文搜索',
    ShellDestination.settings => '设置',
    ShellDestination.library => '智阅',
  };
  return (title: title, showBack: destination != ShellDestination.library);
}

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
        final location = state.uri.toString();
        return Column(
          children: [
            Consumer(
              builder: (context, ref, _) {
                final isReader =
                    shellDestinationFor(location) == ShellDestination.reader;
                final bookTitle =
                    isReader ? ref.watch(viewerProvider).book?.title : null;
                final info =
                    titleBarInfoFor(location, bookTitle: bookTitle);
                return AppTitleBar(
                  title: info.title,
                  showBack: info.showBack,
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
