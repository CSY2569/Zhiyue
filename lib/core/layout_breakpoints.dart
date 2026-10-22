/// Width breakpoints shared by every layout.
///
/// These are pure size facts, not platform facts: a narrow desktop window and
/// a phone use the same compact arrangement. Platform differences live in
/// `lib/platform/platform_host.dart`.
library;

/// Narrow-enough layout to switch panels to modal/full-screen form.
/// 700dp separates phones from tablets in the plan (A3).
bool isCompactWidth(double width) => width < 700;
