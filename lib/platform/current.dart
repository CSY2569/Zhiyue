/// Which platform implementation this checkout builds for.
///
/// THIS FILE IS BRANCH-SPECIFIC.
///  - `main`  -> [DesktopPlatformHost] (Linux / Windows)
///  - `android` -> `AndroidPlatformHost` (Android arm64)
///
/// It is the only file that has to differ between the two branches; every
/// other shared file refers to `PlatformHost.current`. See
/// `docs/BRANCH_SPLIT_PLAN.md`.
library;

import 'package:rbwa/platform/desktop/desktop_host.dart';
import 'package:rbwa/platform/platform_host.dart';

/// The host `main()` installs before the first frame.
const PlatformHost platformHost = DesktopPlatformHost();
