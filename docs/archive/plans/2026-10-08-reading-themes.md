# 内置阅读主题（纸白 / 羊皮纸 / 暗夜）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 阅读器内置三个阅读主题——纸白、羊皮纸（浅色护眼）、暗夜（微信读书深色配方），默认跟随亮/暗模式自动匹配，选择持久化。

**Architecture:** 新增 `ReadingTheme` 模型 + `ReadingPalette`（Flutter `ThemeExtension`，挂在 ThemeData 上随主题下发）。PDF 页面是 pdfium 渲染的位图，浅色主题用 `BlendMode.multiply` 把纸色染到页面白底上（黑字保持黑），暗夜主题用「反相 + 色相旋转 180°」颜色矩阵（文字变白、背景变深，插图色相保持正确）。阅读主题通过 `ReadingThemeScope` 只作用于阅读器路由（工具栏/侧栏/对照面板随之变色），书库/设置页仍走原有 `ThemeMode`。

**Tech Stack:** Flutter (Material 3) + Riverpod (Notifier) + 现有 `SettingsRepository`（Rust settings KV 表）。无新依赖。

## Global Constraints

- 包名前缀：`package:rbwa/`（pubspec `name: rbwa`）。
- 不新增任何依赖；不改动 Rust 侧代码。
- `ColorFiltered` 只能包住页面位图（`RawImage`），**不能**包住选区/标注/命中高亮等覆盖层——标注颜色必须保持真实。
- 截图识图（`screenshot_provider.dart`）按设计是 WYSIWYG（"pixel-identical to what the user sees"），页面着色会进入截图，这是可接受的既定行为，不要为绕过它改动截图链路。
- 每个任务结束运行该任务的测试文件；最后一个任务跑全量 `flutter test` 与 `flutter analyze`（均须通过）。
- UI 文案用中文，风格与设置页现有文案一致（如「目录默认全展开」的 description 句式）。
- 提交信息遵循仓库惯例：`feat(theme): ...` / `feat(reader): ...` / `docs(features): ...`。

## 配色规范（所有任务共用，逐字使用）

| 主题 | 画布 canvas | 页面卡 pageCard | 占位 placeholder | 正文文字 primaryText | 页面着色 |
|---|---|---|---|---|---|
| 纸白 paper | `#F4F2ED` | `#FFFFFF` | `#E8E5DE` | `#2B2B28` | multiply `#FDFBF7`（近白微暖） |
| 羊皮纸 parchment | `#EDE3CC` | `#FBF5E4` | `#E2D6BA` | `#463727` | multiply `#F5ECD4`（米黄染白底） |
| 暗夜 night | `#131417` | `#1F2022` | `#26272B` | `#B9BDC3` | 反相+色相旋转矩阵（白底→`#1F2022`，黑字→`#B9BDC3`） |

暗夜矩阵（invert + hue-rotate 180°，系数逐通道缩放使白底落到 `#1F2022`、黑字落到 `#B9BDC3`，插图色相保持）：

```
R: [ 0.347, -0.864, -0.087, 0, 185]
G: [-0.262, -0.265, -0.089, 0, 189]
B: [-0.269, -0.902,  0.540, 0, 195]
A: [ 0,      0,      0,     1,   0]
```

设置持久化键：`reading_theme`，取值 `auto|paper|parchment|night`，缺省 `auto`（亮色→纸白，暗色→暗夜）。

---

### Task 1: ReadingTheme 模型与调色板

**Files:**
- Create: `lib/core/theme/reading_theme.dart`
- Test: `test/reading_theme_test.dart`

**Interfaces:**
- Produces（后续任务全部依赖这些名字）:
  - `enum ReadingTheme { auto, paper, parchment, night }`
  - `class ReadingPalette extends ThemeExtension<ReadingPalette>`，字段：`theme, brightness, canvas, pageCard, placeholder, primaryText, pageTint(Color?), nightMatrix(List<double>?)`，getter `pageColorFilter → ColorFilter`；静态常量 `ReadingPalette.paper / .parchment / .night`
  - `ReadingTheme resolveReadingTheme(ReadingTheme choice, ThemeMode mode, Brightness platformBrightness)`
  - `ReadingTheme? parseReadingTheme(String raw)`
  - `ReadingPalette readingPaletteFor(ReadingTheme theme)`（传 `auto` 视为 `paper`，调用方须先 resolve）

- [ ] **Step 1: 写失败测试**

`test/reading_theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

void main() {
  group('resolveReadingTheme', () {
    test('auto + light mode -> paper', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.light, Brightness.light),
        ReadingTheme.paper,
      );
    });
    test('auto + dark mode -> night', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.dark, Brightness.light),
        ReadingTheme.night,
      );
    });
    test('auto + system follows platform brightness', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.system, Brightness.dark),
        ReadingTheme.night,
      );
      expect(
        resolveReadingTheme(
            ReadingTheme.auto, ThemeMode.system, Brightness.light),
        ReadingTheme.paper,
      );
    });
    test('explicit choice always wins', () {
      expect(
        resolveReadingTheme(
            ReadingTheme.parchment, ThemeMode.dark, Brightness.dark),
        ReadingTheme.parchment,
      );
      expect(
        resolveReadingTheme(
            ReadingTheme.night, ThemeMode.light, Brightness.light),
        ReadingTheme.night,
      );
    });
  });

  group('parseReadingTheme', () {
    test('round-trips every value and rejects garbage', () {
      for (final t in ReadingTheme.values) {
        expect(parseReadingTheme(t.name), t);
      }
      expect(parseReadingTheme('sepia'), isNull);
    });
  });

  group('night matrix', () {
    // Apply one matrix row to an rgb triple (ColorFilter.matrix semantics:
    // out = sum(k_i * c_i) + offset, channels 0..255, clamped).
    double applyRow(List<double> m, int row, double r, double g, double b) {
      final i = row * 5;
      return (m[i] * r + m[i + 1] * g + m[i + 2] * b + m[i + 4])
          .clamp(0.0, 255.0);
    }

    List<double> apply(List<double> m, double r, double g, double b) =>
        [applyRow(m, 0, r, g, b), applyRow(m, 1, r, g, b), applyRow(m, 2, r, g, b)];

    test('white page lands on #1F2022', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 255, 255, 255);
      expect(out[0], closeTo(31, 3));
      expect(out[1], closeTo(32, 3));
      expect(out[2], closeTo(34, 3));
    });
    test('black ink lands on #B9BDC3', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 0, 0, 0);
      expect(out[0], closeTo(185, 3));
      expect(out[1], closeTo(189, 3));
      expect(out[2], closeTo(195, 3));
    });
    test('illustration hue survives: red stays red', () {
      final m = ReadingPalette.night.nightMatrix!;
      final out = apply(m, 255, 0, 0);
      expect(out[0], greaterThan(200));
      expect(out[1], lessThan(160));
      expect(out[2], lessThan(170));
    });
  });

  group('palettes', () {
    test('paper / parchment are light, night is dark', () {
      expect(ReadingPalette.paper.brightness, Brightness.light);
      expect(ReadingPalette.parchment.brightness, Brightness.light);
      expect(ReadingPalette.night.brightness, Brightness.dark);
    });
    test('light palettes use a multiply tint, night uses the matrix', () {
      expect(ReadingPalette.paper.pageTint, isNotNull);
      expect(ReadingPalette.paper.nightMatrix, isNull);
      expect(ReadingPalette.parchment.pageTint,
          const Color(0xFFF5ECD4));
      expect(ReadingPalette.night.nightMatrix, isNotNull);
      expect(ReadingPalette.night.pageColorFilter, isA<ColorFilter>());
    });
    test('readingPaletteFor maps concrete themes', () {
      expect(readingPaletteFor(ReadingTheme.paper).theme, ReadingTheme.paper);
      expect(readingPaletteFor(ReadingTheme.parchment).theme,
          ReadingTheme.parchment);
      expect(readingPaletteFor(ReadingTheme.night).theme, ReadingTheme.night);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/reading_theme_test.dart`
Expected: 编译失败，`reading_theme.dart` 不存在。

- [ ] **Step 3: 实现**

`lib/core/theme/reading_theme.dart`:

```dart
import 'package:flutter/material.dart';

/// Built-in reading themes (FEATURES 8.11): 纸白 / 羊皮纸 / 暗夜, plus `auto`
/// which follows the app brightness (light -> paper, dark -> night).
enum ReadingTheme { auto, paper, parchment, night }

/// Parses a persisted value back into a [ReadingTheme]; null on unknown.
ReadingTheme? parseReadingTheme(String raw) {
  for (final t in ReadingTheme.values) {
    if (t.name == raw) return t;
  }
  return null;
}

/// Resolves the effective theme: an explicit choice always wins; `auto`
/// maps the effective app brightness (light -> paper, dark -> night).
ReadingTheme resolveReadingTheme(
  ReadingTheme choice,
  ThemeMode mode,
  Brightness platformBrightness,
) {
  if (choice != ReadingTheme.auto) return choice;
  final dark = mode == ThemeMode.dark ||
      (mode == ThemeMode.system && platformBrightness == Brightness.dark);
  return dark ? ReadingTheme.night : ReadingTheme.paper;
}

/// Colors and bitmap filters for one reading theme. Delivered as a
/// [ThemeExtension] so every widget under the reader route can read it via
/// `Theme.of(context).extension<ReadingPalette>()`.
@immutable
class ReadingPalette extends ThemeExtension<ReadingPalette> {
  const ReadingPalette({
    required this.theme,
    required this.brightness,
    required this.canvas,
    required this.pageCard,
    required this.placeholder,
    required this.primaryText,
    this.pageTint,
    this.nightMatrix,
  });

  final ReadingTheme theme;
  final Brightness brightness;

  /// Reader canvas behind the page cards (scaffold background).
  final Color canvas;

  /// Card surface for the translated pane / floating reader panels.
  final Color pageCard;

  /// Page placeholder while a bitmap renders.
  final Color placeholder;

  /// Body text on the reading surface (translated text path, chrome text).
  final Color primaryText;

  /// Multiply tint for page bitmaps (light themes): white areas take the
  /// tint, ink stays dark. Null on the night palette.
  final Color? pageTint;

  /// Invert + hue-rotate-180 matrix (night only): white page -> #1F2022,
  /// black ink -> #B9BDC3, illustration hues preserved. 20 doubles.
  final List<double>? nightMatrix;

  ColorFilter get pageColorFilter => nightMatrix != null
      ? ColorFilter.matrix(nightMatrix!)
      : ColorFilter.mode(pageTint!, BlendMode.multiply);

  static const paper = ReadingPalette(
    theme: ReadingTheme.paper,
    brightness: Brightness.light,
    canvas: Color(0xFFF4F2ED),
    pageCard: Color(0xFFFFFFFF),
    placeholder: Color(0xFFE8E5DE),
    primaryText: Color(0xFF2B2B28),
    pageTint: Color(0xFFFDFBF7),
  );

  static const parchment = ReadingPalette(
    theme: ReadingTheme.parchment,
    brightness: Brightness.light,
    canvas: Color(0xFFEDE3CC),
    pageCard: Color(0xFFFBF5E4),
    placeholder: Color(0xFFE2D6BA),
    primaryText: Color(0xFF463727),
    pageTint: Color(0xFFF5ECD4),
  );

  static const night = ReadingPalette(
    theme: ReadingTheme.night,
    brightness: Brightness.dark,
    canvas: Color(0xFF131417),
    pageCard: Color(0xFF1F2022),
    placeholder: Color(0xFF26272B),
    primaryText: Color(0xFFB9BDC3),
    nightMatrix: _nightMatrix,
  );

  static const _nightMatrix = <double>[
    0.347, -0.864, -0.087, 0, 185, //
    -0.262, -0.265, -0.089, 0, 189,
    -0.269, -0.902, 0.540, 0, 195,
    0, 0, 0, 1, 0,
  ];

  @override
  ReadingPalette copyWith({
    ReadingTheme? theme,
    Brightness? brightness,
    Color? canvas,
    Color? pageCard,
    Color? placeholder,
    Color? primaryText,
    Color? pageTint,
    List<double>? nightMatrix,
  }) {
    return ReadingPalette(
      theme: theme ?? this.theme,
      brightness: brightness ?? this.brightness,
      canvas: canvas ?? this.canvas,
      pageCard: pageCard ?? this.pageCard,
      placeholder: placeholder ?? this.placeholder,
      primaryText: primaryText ?? this.primaryText,
      pageTint: pageTint ?? this.pageTint,
      nightMatrix: nightMatrix ?? this.nightMatrix,
    );
  }

  @override
  ReadingPalette lerp(ReadingPalette? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

/// Maps a (resolved, non-auto) theme to its palette. `auto` defensively
/// falls back to paper -- callers must run [resolveReadingTheme] first.
ReadingPalette readingPaletteFor(ReadingTheme theme) {
  switch (theme) {
    case ReadingTheme.paper:
      return ReadingPalette.paper;
    case ReadingTheme.parchment:
      return ReadingPalette.parchment;
    case ReadingTheme.night:
      return ReadingPalette.night;
    case ReadingTheme.auto:
      return ReadingPalette.paper;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/reading_theme_test.dart`
Expected: 全部通过（9 个测试）。

- [ ] **Step 5: Commit**

```bash
git add lib/core/theme/reading_theme.dart test/reading_theme_test.dart
git commit -m "feat(theme): reading theme palettes and night invert matrix"
```

---

### Task 2: AppTheme 支持阅读主题

**Files:**
- Modify: `lib/core/theme/app_theme.dart`
- Test: `test/reading_theme_test.dart`（追加）

**Interfaces:**
- Consumes: `ReadingPalette`, `readingPaletteFor`（Task 1）
- Produces: `AppTheme.forReadingTheme(ReadingTheme theme) → ThemeData`；`AppTheme.light()` 自带 paper 扩展、`AppTheme.dark()` 自带 night 扩展（保证未包 ReadingThemeScope 的旧测试/页面也有扩展可读）。

- [ ] **Step 1: 追加失败测试**

在 `test/reading_theme_test.dart` 的 `main()` 末尾追加：

```dart
  group('AppTheme.forReadingTheme', () {
    test('night yields dark brightness and canvas surface', () {
      final t = AppTheme.forReadingTheme(ReadingTheme.night);
      expect(t.brightness, Brightness.dark);
      expect(t.scaffoldBackgroundColor, ReadingPalette.night.canvas);
      expect(t.colorScheme.surfaceContainerLow,
          ReadingPalette.night.pageCard);
      expect(t.colorScheme.surfaceContainerHighest,
          ReadingPalette.night.placeholder);
      expect(t.extension<ReadingPalette>()?.theme, ReadingTheme.night);
    });
    test('parchment yields light brightness and canvas surface', () {
      final t = AppTheme.forReadingTheme(ReadingTheme.parchment);
      expect(t.brightness, Brightness.light);
      expect(t.scaffoldBackgroundColor, ReadingPalette.parchment.canvas);
      expect(t.extension<ReadingPalette>()?.theme,
          ReadingTheme.parchment);
    });
    test('stock light/dark themes carry a default palette', () {
      expect(AppTheme.light().extension<ReadingPalette>()?.theme,
          ReadingTheme.paper);
      expect(AppTheme.dark().extension<ReadingPalette>()?.theme,
          ReadingTheme.night);
    });
  });
```

并在文件头部 import 处追加：

```dart
import 'package:rbwa/core/theme/app_theme.dart';
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/reading_theme_test.dart`
Expected: 编译失败，`forReadingTheme` 未定义。

- [ ] **Step 3: 实现**

把 `lib/core/theme/app_theme.dart` 整体替换为：

```dart
import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

/// Application theme definitions (FEATURES 8.2 / 8.11).
///
/// Material 3 light + dark schemes. The seed color is a calm reading-friendly
/// teal; both schemes are generated from it. The reader route additionally
/// overrides the scheme per reading theme via [forReadingTheme] -- canvas /
/// card / text colors then come from the active [ReadingPalette], which is
/// attached as a theme extension so widgets can reach the bitmap filters.
class AppTheme {
  AppTheme._();

  static const _seed = Color(0xFF2E6F6A);

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.light,
    );
    return _base(scheme)
        .copyWith(extensions: const [ReadingPalette.paper]);
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return _base(scheme)
        .copyWith(extensions: const [ReadingPalette.night]);
  }

  /// Theme for the reader route under [theme] (FEATURES 8.11): scaffold
  /// background becomes the palette canvas, cards / placeholders take the
  /// palette surfaces, and the palette itself rides along as an extension.
  static ThemeData forReadingTheme(ReadingTheme theme) {
    final palette = readingPaletteFor(theme);
    final seeded = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: palette.brightness,
    );
    final scheme = seeded.copyWith(
      surface: palette.canvas,
      onSurface: palette.primaryText,
      surfaceContainerLow: palette.pageCard,
      surfaceContainerHighest: palette.placeholder,
    );
    return _base(scheme).copyWith(extensions: [palette]);
  }

  static ThemeData _base(ColorScheme scheme) {
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        centerTitle: true,
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/reading_theme_test.dart`
Expected: 全部通过。

- [ ] **Step 5: 回归确认（light()/dark() 加了扩展不能破坏现有测试）**

Run: `flutter test test/settings_layout_test.dart test/pdf_scroll_test.dart`
Expected: 全部通过。

- [ ] **Step 6: Commit**

```bash
git add lib/core/theme/app_theme.dart test/reading_theme_test.dart
git commit -m "feat(theme): derive reader ThemeData from reading palette"
```

---

### Task 3: ReadingThemeController 持久化 + ReadingThemeScope

**Files:**
- Create: `lib/core/theme/reading_theme_controller.dart`
- Test: `test/reading_theme_controller_test.dart`

**Interfaces:**
- Consumes: `ReadingTheme`, `parseReadingTheme`, `resolveReadingTheme`, `AppTheme.forReadingTheme`（Task 1/2）；`settingsRepositoryProvider`（`package:rbwa/data/repositories/settings_repository.dart`，`getSetting(String) → Future<String?>`、`setSetting(String, String) → Future<int>`）；`themeControllerProvider`（`package:rbwa/core/theme/theme_controller.dart`）
- Produces:
  - `class ReadingThemeController extends Notifier<ReadingTheme>`，`set(ReadingTheme)`
  - `readingThemeControllerProvider`（NotifierProvider）
  - `class ReadingThemeScope extends ConsumerWidget`（`const ReadingThemeScope({super.key, required this.child})`）——解析有效主题并以 `Theme` 覆盖子树，供 Task 6 包住阅读器 Scaffold。

- [ ] **Step 1: 写失败测试**

`test/reading_theme_controller_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';

import 'helpers/fake_settings.dart';

void main() {
  test('hydrates the stored theme from settings', () async {
    final container = ProviderContainer(overrides: [
      settingsRepositoryProvider
          .overrideWithValue(FakeSettings({'reading_theme': 'parchment'})),
    ]);
    addTearDown(container.dispose);
    // Default before the async hydrate lands.
    expect(container.read(readingThemeControllerProvider), ReadingTheme.auto);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(readingThemeControllerProvider),
        ReadingTheme.parchment);
  });

  test('set updates state and persists', () async {
    final fake = FakeSettings();
    final container = ProviderContainer(overrides: [
      settingsRepositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);
    await container
        .read(readingThemeControllerProvider.notifier)
        .set(ReadingTheme.night);
    expect(container.read(readingThemeControllerProvider), ReadingTheme.night);
    expect(fake.writes['reading_theme'], 'night');
  });

  testWidgets('scope applies the explicit choice to its subtree',
      (tester) async {
    ReadingTheme? seen;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider
              .overrideWithValue(FakeSettings({'reading_theme': 'parchment'})),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ReadingThemeScope(
            child: Builder(
              builder: (context) {
                seen = Theme.of(context).extension<ReadingPalette>()?.theme;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(seen, ReadingTheme.parchment);
  });

  testWidgets('scope auto-resolves dark mode to night', (tester) async {
    ReadingTheme? seen;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider
              .overrideWithValue(FakeSettings({'theme': 'dark'})),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.dark,
          home: ReadingThemeScope(
            child: Builder(
              builder: (context) {
                seen = Theme.of(context).extension<ReadingPalette>()?.theme;
                return const SizedBox();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(seen, ReadingTheme.night);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/reading_theme_controller_test.dart`
Expected: 编译失败，`reading_theme_controller.dart` 不存在。

- [ ] **Step 3: 实现**

`lib/core/theme/reading_theme_controller.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/theme_controller.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';

/// Reading-theme preference (FEATURES 8.11): 纸白 / 羊皮纸 / 暗夜 / 跟随亮度.
///
/// Persisted to the `settings` KV table via [SettingsRepository]
/// (`reading_theme` key), mirroring [ThemeController]: hydrate async,
/// persistence failures are non-fatal.
class ReadingThemeController extends Notifier<ReadingTheme> {
  static const _key = 'reading_theme';

  @override
  ReadingTheme build() {
    _hydrate();
    return ReadingTheme.auto;
  }

  Future<void> _hydrate() async {
    try {
      final raw = await ref.read(settingsRepositoryProvider).getSetting(_key);
      if (raw != null) {
        state = parseReadingTheme(raw) ?? ReadingTheme.auto;
      }
    } catch (_) {
      // Core not ready yet (e.g. during tests); keep auto.
    }
  }

  Future<void> set(ReadingTheme theme) async {
    state = theme;
    try {
      await ref.read(settingsRepositoryProvider).setSetting(_key, theme.name);
    } catch (_) {
      // Persistence failure is non-fatal; the in-memory value still applies.
    }
  }
}

/// Riverpod provider for the reading-theme preference.
final readingThemeControllerProvider =
    NotifierProvider<ReadingThemeController, ReadingTheme>(
        ReadingThemeController.new);

/// Applies the effective reading theme to its subtree as a [Theme] override
/// (FEATURES 8.11). Used by the reader route only -- library / settings keep
/// the app-wide light/dark theme. `auto` follows the app brightness.
class ReadingThemeScope extends ConsumerWidget {
  const ReadingThemeScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final choice = ref.watch(readingThemeControllerProvider);
    final mode = ref.watch(themeControllerProvider);
    final platform = MediaQuery.platformBrightnessOf(context);
    final effective = resolveReadingTheme(choice, mode, platform);
    return Theme(data: AppTheme.forReadingTheme(effective), child: child);
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/reading_theme_controller_test.dart`
Expected: 4 个测试全部通过。

- [ ] **Step 5: Commit**

```bash
git add lib/core/theme/reading_theme_controller.dart test/reading_theme_controller_test.dart
git commit -m "feat(theme): persist reading theme choice and scope widget"
```

---

### Task 4: ThemedPageImage + 原文页面上色

**Files:**
- Create: `lib/features/reader/widgets/themed_page_image.dart`
- Create: `test/helpers/test_images.dart`
- Modify: `lib/features/reader/widgets/pdf_page_scroll.dart:892-898`
- Test: `test/themed_page_image_test.dart`

**Interfaces:**
- Consumes: `ReadingPalette.pageColorFilter`（Task 1）
- Produces: `class ThemedPageImage extends StatelessWidget`，构造 `const ThemedPageImage({super.key, required this.image, this.fit = BoxFit.fill, this.filterQuality = FilterQuality.medium})`，字段 `ui.Image image / BoxFit fit / FilterQuality filterQuality`。Task 5 的对照面板复用它。
- Produces: `Future<ui.Image> solidTestImage(Color color)`（test helper，8×8 纯色图）

关键约束：`ColorFiltered` 只包 `RawImage`，下同——标注层（`HighlightLayer`）、选区层（`SelectionLayer`）、命中高亮、图片标注层全部保持未过滤，标注颜色不失真。

- [ ] **Step 1: 写失败测试与 helper**

`test/helpers/test_images.dart`:

```dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// An 8x8 solid-color image for widget tests that need a real [ui.Image]
/// (mirrors the helper in paint_mark_test.dart).
Future<ui.Image> solidTestImage(Color color) {
  final rgba = Uint8List(8 * 8 * 4);
  for (var i = 0; i < 8 * 8; i++) {
    rgba[i * 4] = (color.r * 255).round();
    rgba[i * 4 + 1] = (color.g * 255).round();
    rgba[i * 4 + 2] = (color.b * 255).round();
    rgba[i * 4 + 3] = (color.a * 255).round();
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      rgba, 8, 8, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}
```

`test/themed_page_image_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/features/reader/widgets/themed_page_image.dart';

import 'helpers/test_images.dart';

void main() {
  testWidgets('page bitmap is wrapped in the palette color filter (night)',
      (tester) async {
    final image = await solidTestImage(const Color(0xFFFFFFFF));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forReadingTheme(ReadingTheme.night),
        home: Scaffold(body: ThemedPageImage(image: image)),
      ),
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(find.byType(RawImage), findsOneWidget);
    // The filter must wrap ONLY the bitmap: RawImage is its direct child.
    final filtered = tester.widget<ColorFiltered>(find.byType(ColorFiltered));
    expect(filtered.child, isA<RawImage>());
  });

  testWidgets('paper theme still wraps with its multiply tint',
      (tester) async {
    final image = await solidTestImage(const Color(0xFFFFFFFF));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.forReadingTheme(ReadingTheme.paper),
        home: Scaffold(body: ThemedPageImage(image: image)),
      ),
    );
    expect(find.byType(ColorFiltered), findsOneWidget);
  });

  testWidgets('falls back to paper when no palette is in scope',
      (tester) async {
    final image = await solidTestImage(const Color(0xFFFFFFFF));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ThemedPageImage(image: image))),
    );
    // No crash without a ReadingPalette extension; filter still applies.
    expect(find.byType(ColorFiltered), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/themed_page_image_test.dart`
Expected: 编译失败，`themed_page_image.dart` 不存在。

- [ ] **Step 3: 实现 widget 并接入原文页面**

`lib/features/reader/widgets/themed_page_image.dart`:

```dart
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:rbwa/core/theme/reading_theme.dart';

/// A rendered page bitmap tinted for the active reading theme (FEATURES
/// 8.11). Light themes multiply a paper tint onto the page (white areas take
/// the tint, ink stays dark); the night theme applies an invert +
/// hue-rotate matrix so ink turns light while illustrations keep their hues.
///
/// The [ColorFiltered] wraps ONLY the bitmap: selection / highlight /
/// annotation layers are siblings painted on top, keeping their colors true.
class ThemedPageImage extends StatelessWidget {
  const ThemedPageImage({
    super.key,
    required this.image,
    this.fit = BoxFit.fill,
    this.filterQuality = FilterQuality.medium,
  });

  final ui.Image image;
  final BoxFit fit;
  final FilterQuality filterQuality;

  @override
  Widget build(BuildContext context) {
    final palette =
        Theme.of(context).extension<ReadingPalette>() ?? ReadingPalette.paper;
    return ColorFiltered(
      colorFilter: palette.pageColorFilter,
      child: RawImage(
        image: image,
        fit: fit,
        filterQuality: filterQuality,
      ),
    );
  }
}
```

`lib/features/reader/widgets/pdf_page_scroll.dart`：
在文件头部 import 区追加：

```dart
import 'package:rbwa/features/reader/widgets/themed_page_image.dart';
```

把（约 892-898 行）：

```dart
              Positioned.fill(
                child: RawImage(
                  image: image,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              ),
```

替换为：

```dart
              Positioned.fill(
                child: ThemedPageImage(image: image),
              ),
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/themed_page_image_test.dart`
Expected: 3 个测试全部通过。

- [ ] **Step 5: 回归（页面滚动相关既有测试）**

Run: `flutter test test/pdf_scroll_test.dart test/selection_layer_test.dart test/screenshot_test.dart`
Expected: 全部通过（旧测试未提供 palette 扩展时走 paper 兜底，行为不变）。

- [ ] **Step 6: Commit**

```bash
git add lib/features/reader/widgets/themed_page_image.dart lib/features/reader/widgets/pdf_page_scroll.dart test/helpers/test_images.dart test/themed_page_image_test.dart
git commit -m "feat(reader): tint original pages by reading theme"
```

---

### Task 5: 对照面板（译文窗格）主题化

**Files:**
- Modify: `lib/features/bilingual/widgets/translated_pane.dart`（卡片装饰约 366-377 行；RawImage 约 419 行）
- Test: `test/translated_pane_theme_test.dart`

**Interfaces:**
- Consumes: `ThemedPageImage`（Task 4）、`ReadingPalette` 扩展。
- Produces: 无新名字——译文卡片不再硬编码 `Colors.white`，译文位图与原文共用同一着色逻辑。

- [ ] **Step 1: 写失败测试**

译文卡片只在翻译管线产出页面位图后才渲染，widget 测试里用 fake 仓库走到卡片路径成本很高；这里用源码守卫测试锁定「卡片不再硬编码白色」「译文位图复用 ThemedPageImage」这两条契约，行为回归由既有 `bilingual_test.dart` 覆盖。

`test/translated_pane_theme_test.dart`:

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('translated pane card is theme-driven, not hardcoded white', () {
    final src = File('lib/features/bilingual/widgets/translated_pane.dart')
        .readAsStringSync();
    expect(src.contains('Colors.white'), isFalse,
        reason: 'the translated page card must come from the theme '
            '(surfaceContainerLow), not a hardcoded white');
    expect(src.contains('surfaceContainerLow'), isTrue);
  });

  test('translated page bitmap uses ThemedPageImage', () {
    final src = File('lib/features/bilingual/widgets/translated_pane.dart')
        .readAsStringSync();
    expect(src.contains('ThemedPageImage('), isTrue,
        reason: 'translated bitmaps get the same reading-theme tint as '
            'original pages');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/translated_pane_theme_test.dart`
Expected: FAIL——`translated_pane.dart:370` 仍是 `color: Colors.white`，且无 `ThemedPageImage`。

- [ ] **Step 3: 实现**

`lib/features/bilingual/widgets/translated_pane.dart`：
在 import 区追加：

```dart
import 'package:rbwa/features/reader/widgets/themed_page_image.dart';
```

卡片装饰（约 366-377 行），把：

```dart
            child: Container(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2)),
                ],
              ),
```

替换为：

```dart
            child: Container(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                boxShadow: [
                  BoxShadow(
                      color: theme.colorScheme.shadow.withValues(
                          alpha: theme.brightness == Brightness.dark
                              ? 0.45
                              : 0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2)),
                ],
              ),
```

译文位图（约 419-423 行），把：

```dart
                  Positioned.fill(
                    child: RawImage(
                      image: data.image,
                      fit: BoxFit.fill,
                    ),
                  ),
```

替换为：

```dart
                  Positioned.fill(
                    child: ThemedPageImage(
                      image: data.image!,
                      fit: BoxFit.fill,
                    ),
                  ),
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/translated_pane_theme_test.dart`
Expected: 通过。

- [ ] **Step 5: 回归（双语相关既有测试）**

Run: `flutter test test/bilingual_test.dart test/translated_selection_test.dart test/translated_bitmap_cache_test.dart`
Expected: 全部通过。

- [ ] **Step 6: Commit**

```bash
git add lib/features/bilingual/widgets/translated_pane.dart test/translated_pane_theme_test.dart
git commit -m "feat(bilingual): theme the translated pane, drop hardcoded white card"
```

---

### Task 6: 阅读器路由接入 ReadingThemeScope

**Files:**
- Modify: `lib/features/reader/reader_page.dart`（主 Scaffold，约 250 行）
- Test: 复用 `test/reading_theme_controller_test.dart` 的 scope 测试（Task 3 已覆盖解析与覆盖逻辑）；本任务补一个静态检查测试防止回退。

**Interfaces:**
- Consumes: `ReadingThemeScope`（Task 3）。
- Produces: 阅读器整棵子树（ReaderToolbar / 侧栏 / PdfPageScroll / TranslatedPane / AI 面板）都处在阅读主题 Theme 下。书库 / 设置页 / 自定义标题栏（router ShellRoute 层）不受影响，仍走 app 级亮暗。

- [ ] **Step 1: 写失败测试**

`test/reading_theme_scope_wiring_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'dart:io';

void main() {
  test('reader page wraps its scaffold in a ReadingThemeScope', () {
    final src =
        File('lib/features/reader/reader_page.dart').readAsStringSync();
    expect(src.contains('ReadingThemeScope('), isTrue,
        reason:
            'reader_page.dart must wrap the reader Scaffold in ReadingThemeScope');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/reading_theme_scope_wiring_test.dart`
Expected: FAIL——`reader_page.dart` 尚未引用 `ReadingThemeScope`。

- [ ] **Step 3: 实现**

`lib/features/reader/reader_page.dart`：
import 区追加：

```dart
import 'package:rbwa/core/theme/reading_theme_controller.dart';
```

主分支（约 250 行）把：

```dart
    return Scaffold(
      body: Focus(
```

改为：

```dart
    return ReadingThemeScope(
      child: Scaffold(
        body: Focus(
```

并相应调整该 return 语句的闭合括号（`Scaffold` 变为 `ReadingThemeScope` 的 child，原 Scaffold 的右括号后再补一层右括号）。loading / error 两个提前 return 的 Scaffold 保持不动（过渡态跟随 app 主题即可）。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/reading_theme_scope_wiring_test.dart`
Expected: 通过。

- [ ] **Step 5: 回归（阅读器相关既有测试全量）**

Run: `flutter test test/reader_toolbar_test.dart test/panel_layout_test.dart test/annotation_rail_test.dart test/ai_panel_scroll_test.dart`
Expected: 全部通过。

- [ ] **Step 6: 手动验证（真机看效果，脚本替代不了的一步）**

Run: `flutter run -d linux`
操作清单：
1. 设置 → 外观 → 阅读主题切「羊皮纸」→ 打开一本书：页面位图应染为米黄、画布比页面深半度、工具栏/侧栏随主题变暖。
2. 切「暗夜」：页面白底应变 `#1F2022` 深灰、黑字变浅灰、彩色插图色相不发色（红仍红、蓝仍蓝）；对照面板卡片与原文页一致；标注/选区颜色保持原色。
3. 切「跟随亮度」+ 系统暗色：应等同暗夜。
4. 重启应用：主题选择保留。
5. 书库与设置页不受阅读主题影响。

- [ ] **Step 7: Commit**

```bash
git add lib/features/reader/reader_page.dart test/reading_theme_scope_wiring_test.dart
git commit -m "feat(reader): apply reading theme to the reader route"
```

---

### Task 7: 设置页「阅读主题」选择器

**Files:**
- Modify: `lib/features/settings/settings_page.dart`（build 方法约 230-287 行）
- Test: `test/settings_reading_theme_test.dart`

**Interfaces:**
- Consumes: `readingThemeControllerProvider`（Task 3）、`ReadingTheme`。
- Produces: 设置 → 外观新增「阅读主题」行（主题模式行之后）。

- [ ] **Step 1: 写失败测试**

`test/settings_reading_theme_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:rbwa/core/theme/app_theme.dart';
import 'package:rbwa/data/repositories/ai_repository.dart';
import 'package:rbwa/data/repositories/settings_repository.dart';
import 'package:rbwa/data/repositories/translation_repository.dart';
import 'package:rbwa/features/settings/settings_page.dart';

import 'helpers/fake_ai_repo.dart';
import 'helpers/fake_settings.dart';
import 'helpers/fake_translation_repo.dart';

void main() {
  testWidgets('阅读主题 row persists the selection', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeSettings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiRepositoryProvider.overrideWithValue(FakeAiRepo()),
          translationRepositoryProvider
              .overrideWithValue(FakeTranslationRepo()),
          settingsRepositoryProvider.overrideWithValue(fake),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const SettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('阅读主题'), findsOneWidget);
    await tester.tap(find.text('羊皮纸'));
    await tester.pumpAndSettle();
    expect(fake.writes['reading_theme'], 'parchment');

    await tester.tap(find.text('暗夜'));
    await tester.pumpAndSettle();
    expect(fake.writes['reading_theme'], 'night');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/settings_reading_theme_test.dart`
Expected: FAIL——找不到「阅读主题」。

- [ ] **Step 3: 实现**

`lib/features/settings/settings_page.dart`：
import 区追加：

```dart
import 'package:rbwa/core/theme/reading_theme.dart';
import 'package:rbwa/core/theme/reading_theme_controller.dart';
```

build 方法顶部（`final themeMode = ref.watch(themeControllerProvider);` 之后）追加：

```dart
    final readingTheme = ref.watch(readingThemeControllerProvider);
```

在「外观」`SettingsSection` 的「主题模式」`SettingsControlRow` 之后追加一行：

```dart
                  SettingsControlRow(
                    title: '阅读主题',
                    description: '阅读器界面与页面配色；「跟随亮度」在亮色下为纸白、暗色下为暗夜',
                    child: SegmentedButton<ReadingTheme>(
                      segments: const [
                        ButtonSegment(
                          value: ReadingTheme.auto,
                          label: Text('跟随亮度'),
                          icon: Icon(Icons.brightness_auto_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: ReadingTheme.paper,
                          label: Text('纸白'),
                          icon: Icon(Icons.description_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: ReadingTheme.parchment,
                          label: Text('羊皮纸'),
                          icon: Icon(Icons.auto_stories_outlined, size: 16),
                        ),
                        ButtonSegment(
                          value: ReadingTheme.night,
                          label: Text('暗夜'),
                          icon: Icon(Icons.nightlight_outlined, size: 16),
                        ),
                      ],
                      selected: {readingTheme},
                      showSelectedIcon: false,
                      onSelectionChanged: (s) => ref
                          .read(readingThemeControllerProvider.notifier)
                          .set(s.first),
                    ),
                  ),
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/settings_reading_theme_test.dart`
Expected: 通过。

- [ ] **Step 5: 回归（设置页布局在多宽度下不溢出）**

Run: `flutter test test/settings_layout_test.dart`
Expected: 4 个宽度全部通过；若 560px 窄宽因新增一行 SegmentedButton 溢出，则把该行的 `SegmentedButton` 包一层 `SingleChildScrollView(scrollDirection: Axis.horizontal, child: ...)` 后重跑。

- [ ] **Step 6: Commit**

```bash
git add lib/features/settings/settings_page.dart test/settings_reading_theme_test.dart
git commit -m "feat(settings): reading theme picker"
```

---

### Task 8: 文档与全量回归

**Files:**
- Modify: `docs/FEATURES.md`（第 8 章表格，8.3 行之后）
- Test: 全量测试套件

**Interfaces:**
- Consumes: 全部前序任务。

- [ ] **Step 1: FEATURES.md 增加条目**

在 `docs/FEATURES.md` 第 8 章表格 `| 8.5 |` 行之后（`### 快捷键` 小节之前）插入：

```markdown
| 8.11 | P1 | 阅读主题：纸白 / 羊皮纸 / 暗夜（微信读书深色配方：画布 #131417、页面 #1F2022、文字 #B9BDC3），「跟随亮度」自动匹配（亮→纸白、暗→暗夜）；页面位图按主题着色——浅色 multiply 纸色、暗夜反相+色相旋转 180°（插图色相保持）；着色只作用于页面位图，标注/选区颜色保持真实；对照面板卡片随主题；选择持久化（`reading_theme` 键） |
```

- [ ] **Step 2: 全量回归**

Run: `flutter test`
Expected: 全部通过，0 失败。

Run: `flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add docs/FEATURES.md
git commit -m "docs(features): built-in reading themes 8.11"
```

---

## 非目标（明确不做）

- 阅读器工具栏上的主题快捷切换（本期只进设置页；后续可加）。
- 缩略图栏（ThumbnailRail）位图着色——缩略图保持原始页面颜色，作为导航辨识。
- 截图识图链路绕过主题着色——WYSIWYG 是该功能的既定契约。
- 自定义主题色/用户调色板——只内置三套。

## 后续修正（用户反馈，待办）：主题应为全局而非仅阅读器

用户明确：选纸白 / 羊皮纸 / 暗夜时**整个软件 UI**（书库、设置、标题栏）都要随之变化，不限于阅读器。已交付版本只把 `ReadingThemeScope` 包在阅读器路由上——范围收窄了。修正方案（改动很小，架构已就位）：

1. **把解析挪到 `app.dart`**：`RbwaApp.build` 里 watch 两个控制器 + 平台亮度，resolve 出有效主题后，`MaterialApp(theme: AppTheme.forReadingTheme(effective), themeMode: ThemeMode.light)`（只给单一 ThemeData，不再用 light/dark 配对）；删除 `ReaderPage` 里的 `ReadingThemeScope` 包裹。
2. **设置页合并两个设置**：现有「主题模式」（系统/亮/暗）与「阅读主题」语义重叠——建议删掉「主题模式」行，由「阅读主题 → 跟随亮度」承担系统跟随（FEATURES 8.2/8.3 文案随之并入 8.11）。若要保留两行需先定清语义再动手。
3. **保持不变的部分**：`ThemedPageImage` 位图着色仍只在阅读面生效（书库封面/缩略图不染色）；`ReadingPalette` 扩展、控制器、持久化原样复用；标题栏（ShellRoute）随 MaterialApp 主题自动跟随。
4. **测试**：scope 相关测试改打 `app.dart` 的接线（守卫断言 `app.dart` 含 `forReadingTheme`）；`ai_ui_test` 等直接 pump `AppTheme.light()` 的用例不受影响。

原「非目标」中「自定义标题栏不跟随阅读主题」一条作废——全局化后自然跟随。
