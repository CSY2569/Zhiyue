import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:rbwa/features/library/library_page.dart';
import 'package:rbwa/features/reader/reader_page.dart';
import 'package:rbwa/features/settings/settings_page.dart';

/// Application routes (FEATURES §2/3 + §8.1 navigation).
///
/// Three top-level destinations: library (home), reader (per book), settings.
/// The reader takes a book id path parameter. All pages are skeletons for M1.
final appRouter = GoRouter(
  initialLocation: '/library',
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
      path: '/settings',
      name: 'settings',
      builder: (context, state) => const SettingsPage(),
    ),
  ],
  errorBuilder: (context, state) => Scaffold(
    body: Center(child: Text('Route not found: ${state.uri}')),
  ),
);
