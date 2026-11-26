# 分支策略

长期分支只有两条，职责按**目标平台**划分：

| 分支 | 职责 | 构建产物 |
|---|---|---|
| `main` | **Linux / Windows 桌面版**（主干） | `dist/*.deb`、`dist/*.rpm`、`dist/*.AppImage`，后续 Windows 安装包 |
| `android` | **Android arm64 版** | `dist/ZhiYue-<ver>-arm64-v8a.apk` |

两条分支共享同一套 Flutter UI 与 Rust 核心（`lib/`、`rust/`、`test/`），
差异集中在平台入口与移动端专属实现。

## 改动该落在哪条分支

| 改动类型 | 落点 | 说明 |
|---|---|---|
| Dart 业务逻辑、Rust 核心、数据库、通用组件 | `main` | 平台无关，属于两条分支的共同基础 |
| 桌面端功能（RetainPDF 对照、窗口、打包脚本） | `main` | 只在桌面使用 |
| Android 入口、Gradle、Kotlin 桥、移动布局、文本级翻译 | `android` | 只在移动端使用 |
| 同时影响两端的基础修复（如数据正确性、迁移、缓存） | `main`，再同步到 `android` | 避免两端各修一遍、逐渐分叉 |

## 同步规则

1. **共享修复先落 `main`**，然后在 `android` 上用同步脚本合并：
   ```bash
   git checkout android
   bash scripts/sync-from-main.sh main
   ```
   **不要直接 `git merge main`**：`main` 上不存在 Android 专属文件，git 会把
   `android` 未改动过的这些路径**静默删除**，分支随即失去构建 APK 的能力。
   `sync-from-main.sh` 合并后按 `.platform/android-owned.txt` 从合并前的提交
   恢复这些路径（新增 Android 文件时记得同步更新该清单）。
2. **Android 专属改动不回灌 `main`**，除非它已被抽象成平台无关实现。
3. **不要 rebase 已推送的历史**。
3. 发版前，`android` 必须先合并一次最新的 `main`，确保共享层一致。
4. 两端的版本号独立演进：桌面版与 Android 版可以有不同的 `version`，
   tag 建议加平台后缀（如 `v1.0.0-linux`、`v1.0.0-android`），避免同名 tag 冲突。

## 平台判断写在哪里

所有平台差异都走 `lib/platform/platform_host.dart` 的 `PlatformHost`：

- `PlatformHost.current.touch`：是否触摸优先（触觉、长按选择、长按拖拽）；
- `useCompactLayout(width)`：是否用紧凑布局（触摸设备任意宽度，或窄窗口）；
- `translatedPane(bookId)`：对照阅读的右侧面板（RetainPDF PDF / 文本栏）；
- `readerBars(...)`：阅读器 chrome（桌面单行工具条 / 手机双栏）；
- `wrapReadingSurface(...)`：双指缩放与双击；
- `prepareWindow` / `initCore` / `ensureModels` / `attachLifecycle`：启动链路。

不要在新代码里写 `Platform.isAndroid` 判断；`isCompactWidth(width)`
（`lib/core/layout_breakpoints.dart`）是纯尺寸事实，可以直接用。
Rust 侧继续使用 `cfg!(target_os = "android")`。

`test/platform_boundary_test.dart` 会拦截越界引用。

## 当前状态

拆分已完成：

- `main` 不含 `android/`、Android Kotlin 桥、移动端 widget/provider 与 Android
  测试；`flutter build linux --release` 可用，`flutter build apk` 会失败（预期）。
- `android` 在共享代码之上保留全部 Android 实现，`flutter build apk` 可用。
- 两条分支唯一的差异文件是 `lib/platform/current.dart`（选择平台 host）；
  其余共享文件逐字节相同。
- 每次改完 `api.rs` 都要在两条分支各自执行
  `flutter_rust_bridge_codegen generate` 并一起提交，否则生成的绑定会与实现不符。
