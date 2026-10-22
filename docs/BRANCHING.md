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

1. **共享修复先落 `main`**，然后在 `android` 上合并：
   ```bash
   git checkout android
   git merge main
   ```
   使用 `merge`，不要对已推送的历史做 `rebase`。
2. **Android 专属改动不回灌 `main`**，除非它已被抽象成平台无关实现。
3. 发版前，`android` 必须先合并一次最新的 `main`，确保共享层一致。
4. 两端的版本号独立演进：桌面版与 Android 版可以有不同的 `version`，
   tag 建议加平台后缀（如 `v1.0.0-linux`、`v1.0.0-android`），避免同名 tag 冲突。

## 平台判断写在哪里

运行时差异统一通过 `lib/core/platform/platform.dart` 的 `PlatformCapabilities`
表达（是否移动端、对照阅读走 RetainPDF 还是文本级翻译），不要在业务代码里
直接读 `Platform.isAndroid` 之类的判断。Rust 侧使用 `cfg!(target_os = "android")`。

## 当前状态说明

拆分时 `main` 已包含完整的 Android 实现（`android/` 工程与移动布局），
这条快照保留可构建性，但**后续 Android 开发只在 `android` 分支进行**；
`main` 上的 Android 代码不再更新，也不作为发布依据。
