import 'package:go_router/go_router.dart';

/// Leaves the current screen the way the platform expects.
///
/// The app now *pushes* detail screens (reader / settings / search / AI chat)
/// onto the navigator stack instead of replacing the location. That makes the
/// Android back gesture and the in-app back buttons behave identically: pop
/// one screen. A deep link (or the first screen) has nothing to pop, so we
/// fall back to the library instead of letting the OS close the app.
///
/// [router] is passed explicitly because a few surfaces (the shell title bar)
/// live above the page subtree and cannot rely on `context.pop()`.
void navigateBack(GoRouter router, {String fallback = '/library'}) {
  if (router.canPop()) {
    router.pop();
  } else {
    router.go(fallback);
  }
}
