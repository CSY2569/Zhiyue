# 两端差异说明（Linux 桌面 / Android）

对照分支：`main`（Linux，`6ab98a0`）与 `android`（Android，`e825ad4`）。
截图见 `screenshots/platform-split/`（不纳入版本库）。

## 一、代码层面的差异

两条分支的共享代码逐字节相同，**唯一的差异文件是 `lib/platform/current.dart`**：

```dart
// main
const PlatformHost platformHost = DesktopPlatformHost();

// android
const PlatformHost platformHost = AndroidPlatformHost();
```

其余差异全部体现为「`android` 分支多出的文件」：

| 类别 | 文件 | 说明 |
|---|---|---|
| 平台实现 | `lib/platform/android/android_host.dart` | 唯一实现 `PlatformHost` 的 Android 版本 |
| 原生工程 | `android/`（63 文件） | Gradle、Kotlin 桥、自适应图标、资源 |
| Android 通道 | `lib/core/platform/platform.dart`（`PlatformBridge`） | `rbwa/models`、`rbwa/system` 两个 MethodChannel |
| 刷新率 | `lib/core/platform/refresh_rate.dart` | 30–120Hz 逐表面提示 + `RefreshRateScope` |
| 移动 UI | `phone_reader_chrome.dart`、`translated_text_column.dart` | 手机双栏 chrome、文本级译文列 |
| 移动数据 | `page_text_translation_provider.dart`、`text_translation_repository.dart` | 逐块 LLM 翻译与缓存 |
| 构建/文档 | 3 个 `scripts/*android*`、3 个 `docs/ANDROID_*.md` | — |
| 测试 | 4 个（`phone_layout`、`reader_tap`、`text_translation`、`refresh_rate`） | — |

`main` 上没有这些文件；`android` 上多出 78 个文件。

## 二、运行时行为差异

| 维度 | Linux（DesktopPlatformHost） | Android（AndroidPlatformHost） |
|---|---|---|
| 启动 | `windowManager` 无边框窗口 1280×800 | 无窗口管理；`PlatformBridge.init()` 先武装通道 |
| 数据目录 | XDG `~/.local/share/RBWA` | `filesDir`（`/data/user/0/…/files`），由 Kotlin 提供 |
| pdfium | bundle 内 `lib/` | `nativeLibraryDir`，由 Kotlin 提供 |
| OCR 模型 | 安装包内 `models/` 直接用 | 首次启动从 assets 复制 ~210MB，带进度界面 |
| 内存压力 | 无（靠字节预算 LRU） | `onTrimMemory` → 清位图缓存，临界时清 live images |
| 阅读器 chrome | 单行 32dp 工具条（缩略图/目录/标注/视图/缩放/翻页） | 顶部返回+书名+页码 + 底部 5 项操作栏，中部点按隐藏 |
| 对照阅读 | RetainPDF 版式保留 PDF（左右各半） | 文本级译文列；手机上原文/译文分段切换 |
| 缩放 | Ctrl+滚轮 | 双指捏合 + 双击切换 1.2/2.0 |
| 翻页 | 滚轮 / 工具条 / 翻页键 | 边缘点按 / 音量键 / 底部栏 |
| 沉浸模式 | 无 | `immersiveSticky` + 屏幕常亮 |
| 刷新率 | 不干预 | 活动时请求面板最高档，静置 900ms 降到 30Hz |
| 触觉反馈 | 空转 | tap/select/success/warning 四档 |
| 截图保存 | `~/Pictures/RBWA` | 临时目录 |
| 多选/长按 | 右键菜单（拖拽归类） | 长按菜单 + 批量多选栏 |
| 外部文件 | 无 | ACTION_VIEW / ACTION_SEND 导入 |

## 三、布局断点（两端共用）

| 判断 | 语义 | 本次修复 |
|---|---|---|
| `phoneLayout(width)` | `touch && width < 700` | 抽屉侧栏、双栏 chrome、单栏对照 |
| `compactUi(width)` | `touch \|\| width < 700` | 工具条/卡片/输入框改为紧凑堆叠 |

拆分时这两种语义被错误合并成一个，导致 **776dp 平板**（触摸但宽）退化成手机布局：书库丢了导航侧栏换成抽屉。已修复并加 `test/platform_host_test.dart` 守卫。

## 四、实际效果

### 书库
- **Linux**：左侧常驻 208dp 导航栏 + 右侧悬浮内容面板；4 列书卡；右上角主题/设置图标。
- **Android（776dp 平板）**：同样是**左侧常驻导航栏**（证明 `phoneLayout` 正确返回 false）+ 顶部胶囊筛选；书卡 2 列（受平板宽度与卡宽下限约束）。
- 差异：Android 顶部有系统状态栏；书卡进度显示"已读 19 / 320"。

### 阅读器
- **Linux**：顶部单行工具条（图标+文字），页面居中，底部无栏。
- **Android**：顶部返回箭头 + 左对齐书名 + 右侧页码与"更多"，底部 5 项（缩略图/目录/批注/AI/更多），页面居中且可点按中部隐藏两条栏。
- 差异：Android 内容区上下留有 chrome 空间；桌面整屏都是阅读区。

### 本次实机发现并修复的 Android 缺陷
1. **启动即失败**：`core init failed: Android filesDir unavailable`。重构时漏掉 `PlatformBridge.init()`，通道未武装 → `filesDir()` 返回 null → 落到"数据初始化失败"页。已移入 `AndroidPlatformHost.prepareWindow()`。
2. **双标题栏**：shell 为阅读器路由画了返回栏，手机 chrome 又有一条，Android 上叠成两行。已让 touch 平台的阅读器隐藏 shell 标题栏（桌面不变）。

## 五、验证

| 项目 | main | android |
|---|---|---|
| `flutter analyze` | 0 | 0 |
| `flutter test` | 316 | 332 |
| 构建 | `flutter build linux --release` ✅ | `flutter build apk --release` ✅ 281.3MB |
| 实机 | 截图 `linux-*.png` | 小米平板 25091RP04C / Android 17，截图 `android-*.png` |

## 六、尚未统一的部分

- `pubspec.yaml` 两端依赖相同（Android 暂无独有依赖；`window_manager` 在 Android 上不生效但无害）。
- Windows runner 未创建（按计划等桌面功能稳定）。
- `docs/ANDROID_*.md` 只在 `android` 分支；`main` 的 README 仍列 Android 章节，后续可改为"见 android 分支"。
