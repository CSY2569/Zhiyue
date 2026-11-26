# 平台与分支

> 三个目标平台映射到两条长期分支。平台差异**全部**收敛在 `lib/platform/` 的 `PlatformHost` 抽象后面。

---

## 1. 平台 ↔ 分支映射

| 平台 | 分支 | 构建产物 | 状态 |
|---|---|---|---|
| Linux 桌面 | `main`（主干） | `dist/*.deb`、`*.rpm`、`*.AppImage` | ✅ 可构建发行 |
| Windows 桌面 | `main`（共用） | 待定（`.msix` / `.exe`） | ⚠️ runner 未创建 |
| Android arm64 | `android` | `dist/ZhiYue-<ver>-arm64-v8a.apk` | ✅ 可构建发行 |

两条分支共享 `lib/`、`rust/`、`test/`。**逐字节唯一的差异文件是 `lib/platform/current.dart`**：

```dart
// main
const PlatformHost platformHost = DesktopPlatformHost();
// android
const PlatformHost platformHost = AndroidPlatformHost();
```

其余差异体现为 `android` 分支**多出的文件**（约 78 个）：`android/` 原生工程、`lib/platform/android/`、
移动 UI（`phone_reader_chrome.dart`、`translated_text_column.dart`）、Android 通道、4 个移动端测试。

---

## 2. 改动该落在哪条分支

| 改动类型 | 落点 |
|---|---|
| Dart 业务逻辑、Rust 核心、数据库、通用组件 | `main` |
| 桌面端功能（RetainPDF 对照、窗口、打包脚本） | `main` |
| Android 入口、Gradle、Kotlin 桥、移动布局、文本级翻译 | `android` |
| 同时影响两端的基础修复 | `main`，再同步到 `android` |

---

## 3. 同步规则（有陷阱）

```bash
git checkout android
bash scripts/sync-from-main.sh main
```

**不要直接 `git merge main`。** `main` 上不存在 Android 专属文件，git 会把 `android` 分支上
这些未改动的路径**静默删除**，分支随即失去构建 APK 的能力。

`scripts/sync-from-main.sh` 的做法：记下合并前的提交 → `git merge --no-commit --no-ff` →
按 `.platform/android-owned.txt` 清单从合并前提交逐行 `git checkout` 恢复 → 统一提交。

- 新增 Android 专属文件**必须**同步更新 `.platform/android-owned.txt`，否则下次同步会静默删掉它。
- 脚本会拒绝在 `main` 上运行，也会拒绝有未提交**已跟踪**改动的情况（untracked 不挡）。
- 每次改 `api.rs` 都要在两条分支各自跑 `flutter_rust_bridge_codegen generate` 并一起提交。

---

## 4. PlatformHost 抽象

所有平台差异走 `lib/platform/platform_host.dart`（接口 15 个方法，全部有默认实现，默认 `DesktopPlatformHost`）：

| 分类 | 方法 |
|---|---|
| 能力探测 | `touch`、`phoneLayout(w)`、`compactUi(w)`、`needsModelInstall` |
| 启动链路 | `prepareWindow()`、`initCore()`、`attachLifecycle(container)`、`ensureModels(onProgress)`、`wrapApp(child)`、`takeIncomingFiles()` |
| 阅读器差异 | `translatedPane(bookId)`、`readerBars(...)`、`wrapReadingSurface(...)`、`readerEntered()` / `readerExited()`、`handleReaderKey(...)` |

**硬规则**：
- 新代码里**禁止**写 `Platform.isAndroid`（`platform_host.dart` 明令）。平台差异一律加一个 `PlatformHost` 成员。
- 纯尺寸判断可以直接用 `isCompactWidth(width)`（`core/layout_breakpoints.dart`），它是尺寸事实，不是平台事实。
- Rust 侧继续用 `cfg!(target_os = "android")`。
- `test/platform_boundary_test.dart` 会拦截越界引用。

### 布局断点：两种语义，不要合并

| 判断 | 语义 | 用途 |
|---|---|---|
| `phoneLayout(width)` | `touch && width < 700` | 抽屉侧栏、双栏 chrome、单栏对照 |
| `compactUi(width)` | `touch \|\| width < 700` | 工具条 / 卡片 / 输入框改为紧凑堆叠 |

> 历史上这两个语义曾被错误合并，导致 **776dp 平板**（触摸但宽度够）退化成手机布局——书库丢了常驻导航栏换成抽屉。已修复并有 `test/platform_host_test.dart` 守卫。

---

## 5. 运行时行为差异（Linux vs Android）

| 维度 | Linux（DesktopPlatformHost） | Android（AndroidPlatformHost） |
|---|---|---|
| 启动 | `window_manager` 无边框窗口 1280×800 | 无窗口管理；`PlatformBridge.init()` 先武装 MethodChannel |
| 数据目录 | XDG `~/.local/share/RBWA` | 应用私有 `filesDir`，由 Kotlin 提供 |
| pdfium | bundle 内 `lib/` | `nativeLibraryDir`，由 Kotlin 提供 |
| OCR 模型 | 安装包内 `models/` 直接用 | 首次启动从 assets 复制 ~210MB（带进度界面） |
| 内存压力 | 无（靠字节预算 LRU） | `onTrimMemory` → 清位图缓存 |
| 阅读器 chrome | 单行 32dp 工具条 | 顶部返回+书名+页码，底部 5 项操作栏，中部点按隐藏 |
| 对照阅读 | RetainPDF 版式保留 PDF（左右各半） | 文本级译文列，原文/译文分段切换 |
| 缩放 | Ctrl+滚轮 | 双指捏合 + 双击 1.2/2.0 |
| 翻页 | 滚轮 / 工具条 / 翻页键 | 边缘点按 / 音量键 / 底部栏 |
| 刷新率 | 不干预 | 活动时最高档，静置 900ms 降到 30Hz |
| 触觉反馈 | 空转 | tap / select / success / warning 四档 |
| 外部文件 | 无 | ACTION_VIEW / ACTION_SEND 导入 |
| 翻译 | RetainPDF 内置引擎（整本） | 块级 LLM 翻译（无 AGPL 负担） |

---

## 6. 新增一个平台

1. 建 `lib/platform/<plat>/<plat>_host.dart`，继承 `PlatformHost`，**只覆写有差异的方法**（其余走默认实现）。
2. 改 `lib/platform/current.dart` 一行，指向新的 host。
3. 平台专属的通道 / 原生工程放在该平台目录，并登记到 `.platform/` 清单（若该平台独占分支）。
4. 需要新差异点时，先给 `PlatformHost` 加成员**并写共享默认实现**，再让各平台覆写——这样未覆写的平台自动继承合理行为。

### Windows 的现状与待办

Windows 是三个目标平台之一，但 `windows/` runner **尚未创建**，因此当前无法构建。要落地需要：

1. `flutter create --platforms=windows .` 生成 `windows/` runner；
2. 让 pdfium 在 Windows 可用——`scripts/fetch_pdfium.sh` 目前只覆盖 Linux/macOS，需补 `pdfium-win-x64` 分支；
3. 在 `PlatformHost` 补 Windows 的 `prepareWindow`（窗口装饰）与模型目录解析；
4. `rust/Cargo.toml` 的 `reqwest`/`rusqlite` 在 Windows 下应可直接编译，但 pdfium 动态库加载路径要单独验证。

> 桌面两端共用同一套代码，因此 Linux 侧的功能改动天然对 Windows 生效——真正需要补的只有 runner 与动态库加载。
