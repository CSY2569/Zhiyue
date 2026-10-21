# Android 触屏与移动端专项优化方案

> 状态：**方案稿**（2026-10-20，待确认后实施）
> 前置：Android v1 已交付（阅读 / OCR / 划词 AI / 文本对照），见
> [`ANDROID_V1_PLAN.md`](ANDROID_V1_PLAN.md) 与 `IMPLEMENTATION_STATUS.md` §3.23–3.25。
> 本文只覆盖**触摸屏与移动设备**的交互、系统集成与性能，不改桌面行为。

## 0. 现状审计：手机上实际不可用的地方

以下不是"体验不够好"，而是当前版本在 360dp 手机上会出错或无法操作。代码位置已核对。

| # | 问题 | 现状 | 影响 |
|---|---|---|---|
| D1 | **阅读工具栏溢出** | `reader_toolbar.dart` 在 48dp 单行里放了 3 个侧栏钮 + 对照 + 模式 + 缩放 3 钮 + 百分比 + 翻页 3 控件 + 批注 + 识图 + AI，合计约 700dp | 360dp 屏幕必然溢出；右侧按钮点不到 |
| D2 | **选区浮动条越界崩溃** | `floating_toolbar.dart` 用 `_estWidth = 760` 估算宽度，`clamp(8, screen.width - 760 - 8)` 在手机上上界为负 | Dart `clamp` 抛 `ArgumentError`，长按选词后工具条直接异常 |
| D3 | **双页模式在手机上无意义** | 模式选择器无条件提供 单页/双滚/双翻 | 360dp 下每页约 170dp，正文无法阅读 |
| D4 | **书库工具栏溢出** | `library_toolbar.dart` 搜索框固定 280dp + 4 个动作按钮 + 手机端新增的抽屉按钮 | 窄屏溢出，搜索框挤压 |
| D5 | **结果卡尺寸固定** | `PanelLayout.cardSize = 440×360` | 宽度超过手机屏宽，卡片右侧被裁掉 |
| D6 | **AI 对话页是左右分栏** | `ai_conversations_page.dart` 顶层 `Row` | 手机上列表与详情互相挤压 |
| D7 | **批注工具条是单行** | `mark_toolbar.dart` 约 500dp 的 `Row(mainAxisSize.min)` | 窄屏溢出，撤销/样式控件不可达 |
| D8 | **选区没有手柄** | 长按即选中手指下的字符，拖动按字符扩展 | 无法精确调整起止点；与系统阅读器习惯不符 |
| D9 | **无词级吸附** | 长按落在任意字符 | 选中的是半个词，需要手动拖准 |
| D10 | **内存压力回调未接线** | `PlatformBridge.onTrimMemory` 与 Kotlin `SystemBridge` 都已实现，Dart 从未订阅 | 系统内存紧张时不会主动释放位图缓存 |
| D11 | **无沉浸模式 / 常亮** | 无 `SystemUiMode`、无 keep-screen-on | 阅读时状态栏占位；长时间阅读熄屏 |
| D12 | **不能从其他应用打开** | Manifest 只有 LAUNCHER | 文件管理器/微信里"用其他应用打开"找不到智阅 |
| D13 | **触控目标偏小** | 书库收藏按钮约束 28×28；工具按钮 `visualDensity.compact` | 低于 Material 48dp 建议，误触率高 |
| D14 | **刷新率只按活动升降** | 已接入 30–120Hz 策略 | 阅读翻页瞬间仍可能落在低档（首帧延迟） |

## 1. 设计原则

1. **拇指优先**：手机上的高频操作放在屏幕下 1/3；顶部只保留标题与低频入口。
2. **一个手势一件事**：单指拖动=滚动，长按=选择，双指=缩放，双击=缩放切换；
   不为同一手势叠加两种语义。
3. **内容优先**：阅读页默认全屏内容，工具栏/页码作为可召唤的 chrome，点击
   内容区或向下轻扫即隐藏。
4. **即时反馈**：长按、选中、翻页、删除都给触觉反馈；所有点击 100ms 内有视觉响应。
5. **触控目标 ≥ 48dp**：视觉尺寸可小，命中区域必须够。
6. **省电不省体验**：活动时拉满刷新率，静止降频；后台停止预取与流式渲染。
7. **平台差异集中**：继续用 `PlatformCapabilities` 分叉，桌面 widget 与测试快照不变。

## 2. 手势模型（目标状态）

| 手势 | 阅读页 | 说明 |
|---|---|---|
| 单指拖动 | 垂直滚动 | 不变 |
| 单指轻点（内容区中部） | 显示/隐藏 chrome | 新增；chrome 含顶部返回、底部工具栏、页码 |
| 单指轻点（左右边缘 18%） | 上一页 / 下一页 | 新增；单页模式下平滑滚动到相邻页 |
| 长按文字 400ms | 选中该词 + 震动 + 起止手柄 | 取代"选中手指下字符" |
| 拖动选区手柄 | 按词/行扩展选区 | 新增；手柄命中区 32dp |
| 双指捏合 | 缩放 | 已有 |
| 双击 | 1.2× ↔ 2.0× | 已有；双击词则选词（优先） |
| 左右滑动（双页模式） | 翻页 | 已有，仅平板/横屏保留 |
| 系统返回手势 | 先关 chrome / 面板，再退阅读器 | 已有 `PopScope`；chrome 纳入层级 |
| 从顶部下拉 | 不拦截 | 保留系统通知栏 |

> 竖直亮度手势、音量键翻页属于阅读器进阶习惯，放 P2，默认关闭。

## 3. 分项方案

### P0 — 可用性修复（先做，3–4 天）

#### 3.1 阅读页面板化（解决 D1）

- 新增 `PhoneReaderChrome`：
  - **顶部**：一条 44dp 的半透明条（返回、书名、页码、更多），替代当前
    "shell 标题栏 + ReaderToolbar"两层叠加。
  - **底部**：48dp 操作栏，放最高频 5 项：目录、缩略图、批注、AI、更多。
    更多面板（bottom sheet）里放视图模式、缩放、对照、识图、搜索等。
- 平板/桌面继续用现有 `ReaderToolbar`（≥700dp）。
- 实现：`reader_page.dart` 用 `LayoutBuilder` + `PlatformCapabilities` 选择
  chrome；`reader_toolbar.dart` 拆出可复用的按钮组，避免复制逻辑。

#### 3.2 选区工具条改为底部操作条（解决 D2）

- 手机：长按选中后，工具条固定在**底部安全区上方**（`SafeArea` + 48dp），
  8 个动作按 4×2 网格排列，不再浮在选区上方。
- 平板：保留浮动工具条，但宽度改为**实测**（`GlobalKey` + 首帧测量，或
  `LayoutBuilder` 约束），不再用 760 常量；`clamp` 前先保证 `lower <= upper`。
- 顺带修：浮条拖动在手机上禁用（底部固定），平板上保留。

#### 3.3 窄屏模式收敛（解决 D3）

- 宽度 < 700dp 时：
  - 模式选择器只显示"单页"；双击页面不再切换双页。
  - 若历史进度存的是双页模式，打开时自动降级为单页并在下次保存时写回。
- 横屏手机（宽度 ≥ 700dp）允许双页。

#### 3.4 书库工具栏自适应（解决 D4）

- 搜索框改 `Expanded`，最小 120dp；动作按钮在窄屏收进"更多"菜单。
- 导入按钮保留悬浮球（已有）。

#### 3.5 结果卡与对话页（解决 D5/D6）

- 手机：`ResultCard` 改为**底部可拖拽面板**（初始 45% 高，可上拉到 90%，
  下滑关闭），宽度铺满；输入框随键盘上移。
- `AiConversationsPage`：窄屏改为"列表 → push 详情"，平板保持分栏。

#### 3.6 批注工具条（解决 D7）

- 手机改为底部两行：第一行工具（选择/画笔/形状/便签/印章），第二行
  撤销/重做/颜色/粗细；或整体放进"更多"面板。
- 平板上保持单行，允许横向滚动作为兜底。

#### 3.7 基础触屏规范（D13）

- 全局审计：所有 `IconButton` / 自定义点击区的最小命中尺寸 ≥ 48×48
  （`ConstrainedBox` + `behavior: HitTestBehavior.opaque`）。
- 书库收藏按钮：视觉 20dp，命中区扩到 48dp。
- 文本缩放：`MediaQuery.textScaler` 上限 1.3，避免大字号撑破工具栏。

### P1 — 触屏体验核心（6–8 天）

#### 3.8 词级选区 + 手柄（D8/D9）

- 模型：`Selection` 增加 `anchorWordStart / anchorWordEnd`，或新增
  `SelectionHandle` 状态；`selection_geometry.dart` 提供
  `wordRangeAt(boxes, index)`（CJK 按单字成词，拉丁按空白/标点断词）。
- 交互：
  1. 长按 → 取词 → `HapticFeedback.mediumImpact()` → 显示工具条 + 两个手柄；
  2. 拖动手柄 → 按词扩展；手柄之间允许反向拖（跨行自动交换）；
  3. 点击空白 → 清除（已有）。
- 手柄绘制：在 `SelectionLayer` 的 `CustomPaint` 里画 2 个 12dp 圆点 +
  32dp 命中圆；`GestureDetector` 用 `onPanStart` 判断落点是否在手柄上，
  命中则进入"调手柄"模式，否则进入"重新选择"模式。
- 双击词：选词（与双击缩放冲突时，落在文字上优先选词，落在空白处缩放）。

#### 3.9 触觉与反馈

- 新增 `core/haptics.dart`：`tap` / `select` / `pageTurn` / `warning` 四档，
  统一 `HapticFeedback` 调用并做平台判断。
- 接入：长按选词、翻页、删除确认、OCR 完成、翻译失败。

#### 3.10 边缘翻页与 chrome 开关

- 单页模式：左右各 18% 宽度为翻页热区，中部为 chrome 开关。
- 用 `GestureDetector` 的 `onTapUp` + 位置判断实现；双击识别器会延迟单击，
  可接受（系统阅读器同样如此）。
- 翻页动画：`animateTo` 到相邻页，300ms；连续点击合并。

#### 3.11 沉浸模式与常亮（D11）

- 阅读页进入时：`SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)`；
  退出阅读器恢复 `edgeToEdge`。
- 常亮：新增 `rbwa/system` 方法 `setKeepScreenOn(bool)`，Kotlin 侧给
  `window.addFlags(FLAG_KEEP_SCREEN_ON)`；阅读页可见时开启，离开关闭。
- 设置项："阅读时保持屏幕常亮"，默认开。

#### 3.12 打开方式与分享导入（D12）

- Manifest 增加：
  - `ACTION_VIEW`：`application/pdf`、`image/*`；
  - `ACTION_SEND`：`application/pdf`、`image/*`（作为分享目标）。
- `MainActivity` 处理 `onCreate` / `onNewIntent`：把 `content://` 复制到
  `cacheDir/incoming/`，通过 `rbwa/system` 的 `takeIncomingFile()` 交给 Dart；
  Dart 启动后调用现有 `importFiles`。
- 冷启动（intent 首次）与热启动（已在后台）都要覆盖。
- 单例 `singleTop` 已有，`onNewIntent` 必须实现。

#### 3.13 内存压力接线（D10）

- `main.dart` 启动时 `PlatformBridge.onTrimMemory(...)`：
  - `TRIM_MEMORY_RUNNING_LOW`：清空缩略图缓存与非当前页位图；
  - `TRIM_MEMORY_RUNNING_CRITICAL`：清空全部位图缓存（当前页保留）；
  - 同时 `imageCache.clear()` / `imageCache.clearLiveImages()`。
- 为 `BitmapCache` 增加 `trim({int? keepPage})`。

#### 3.14 后台与预取治理

- `AppLifecycleState.paused`：取消进行中的预取、停止刷新率活动定时器；
- `resumed`：恢复。
- AI 流式回答在后台继续（用户预期），但 UI 更新节流到 500ms，回到前台刷新一次。

#### 3.15 刷新率细化（D14）

- 翻页/缩放动画开始时立即请求高刷（不等首帧触摸事件）；
- `PageView` / `animateTo` 前后调用 `notifyActivity()`；
- 阅读页静止且无动画 1.5s 后降到 30Hz（比全局 0.9s 更宽松，减少升降频抖动）。

### P2 — 进阶移动体验（可选，5–8 天）

| 项 | 说明 | 价值 |
|---|---|---|
| 视口分块渲染 | 高倍缩放（>2.5×）只渲染可见区域，而非整页 12MP | 高倍阅读更清晰、内存更低；需先验证 pdfium-render 的矩阵/裁剪能力 |
| 自适应渲染 DPI | 适配宽度时按 2.0× 渲染，放大到 1.5× 以上再升到设备 DPR | 浏览时内存减半；文字仍清晰（放大后自动 sharpen） |
| 音量键翻页 | `KeyEvent` 拦截 `volumeUp/Down` | 单手阅读习惯 |
| 左侧竖直滑动调亮度 | 手势层 + 屏幕亮度通道 | 夜间阅读 |
| 书库多选 | 长按进入多选，批量收藏/分类/删除 | 整理大量书籍 |
| 阅读进度条抽屉 | 底部细进度条，拖动跳页 | 长文档导航 |
| 手势导航边缘冲突处理 | 双页横滑与系统返回竞争时，优先系统手势 | 避免误翻页 |

## 4. 性能专项（与交互并行）

### 4.1 渲染 DPI 分档（建议纳入 P1）

当前 `dpiScale = devicePixelRatio`（手机常见 2.75–3.5），A4 页在 1.2× 缩放下
约 2100×3000 px ≈ 26MB/页。浏览时 Byte 预算 96MB 只能放 3–4 页。

建议：
- 适配宽度（zoom ≤ 1.25）时 `effectiveDpr = min(dpr, 2.0)`；
- zoom > 1.25 时恢复到设备 DPR（细节阅读需要）；
- 缩放跨越阈值时沿用现有 `_maybeSharpen` 重新渲染，不做双缓存。

预期：浏览态内存降 40–55%，翻页更少触发淘汰；文字在 2× 下仍高于阅读所需
（6 英寸屏、30cm 距离约为 1.5× 可辨）。

### 4.2 预取调度

- Rust 侧 pdfium 全局串行（`PDFIUM_LOCK`），预取会和可见页渲染抢锁。
- 方案：Dart 侧 `RenderScheduler`，单一队列 + 优先级（可见页 > 相邻页 >
  缩略图）；预取仅在"可见页渲染完成 + 滚动停止 300ms"后启动；
- 可见页请求到来时，预取任务在**开始下一次渲染前**让位（Rust 无法中途取消）。

### 4.3 帧预算验收

| 指标 | 目标（60Hz / 120Hz） |
|---|---|
| 滚动 jank 率 | < 2% / < 3% |
| P90 帧耗时（build+raster） | ≤ 16.7ms / ≤ 8.3ms |
| 翻页首帧 | ≤ 120ms（已缓存页） |
| 选区拖动手感 | 无 > 24ms 的帧 |
| 冷启动到书库 | ≤ 2.5s |
| 阅读 30 分钟内存增长 | < 50MB，无持续爬升 |

## 5. 代码改动清单

| 文件 | 改动 | 优先级 |
|---|---|---|
| `lib/features/reader/widgets/reader_toolbar.dart` | 拆出按钮组；窄屏走 `PhoneReaderChrome` | P0 |
| `lib/features/reader/widgets/phone_reader_chrome.dart` | 新增：顶部条 + 底部操作栏 + 更多面板 | P0 |
| `lib/features/reader/reader_page.dart` | chrome 状态、点击热区、沉浸、常亮、返回层级 | P0/P1 |
| `lib/features/annotation/widgets/floating_toolbar.dart` | 实测宽度；手机底部 4×2 条 | P0 |
| `lib/features/annotation/widgets/selection_layer.dart` | 词级吸附、起止手柄、双击选词、震动 | P1 |
| `lib/features/annotation/models/selection.dart` | 手柄 / 词边界状态 | P1 |
| `lib/features/annotation/providers/selection_provider.dart` | 手柄拖动状态 | P1 |
| `lib/features/annotation/selection_geometry.dart` | `wordRangeAt` 等纯函数 | P1 |
| `lib/features/annotation/widgets/mark_toolbar.dart` | 窄屏两行 / 底部 | P0 |
| `lib/features/library/widgets/library_toolbar.dart` | 搜索框 Expanded + 动作溢出 | P0 |
| `lib/features/library/widgets/book_tile.dart` | 收藏按钮命中区 48dp | P0 |
| `lib/features/ai/widgets/result_card.dart` | 手机底部面板 | P0 |
| `lib/features/ai/pages/ai_conversations_page.dart` | 窄屏列表 → 详情 | P0 |
| `lib/core/haptics.dart` | 新增 | P1 |
| `lib/core/platform/platform.dart` | `setKeepScreenOn` / `takeIncomingFile` / 内存回调接线 | P1 |
| `lib/features/reader/providers/bitmap_cache.dart` | `trim()`、DPI 分档 | P1/P2 |
| `lib/features/reader/providers/render_scheduler.dart` | 新增：优先级队列 | P1 |
| `lib/features/reader/widgets/pdf_page_scroll.dart` | 模式收敛、翻页动画触发高刷 | P0/P1 |
| `android/.../SystemBridge.kt` | 常亮、incoming 文件、UI 模式 | P1 |
| `android/.../MainActivity.kt` | `onNewIntent`、intent 处理 | P1 |
| `android/app/src/main/AndroidManifest.xml` | `ACTION_VIEW` / `ACTION_SEND` 过滤器 | P1 |
| `test/**` | 手机尺寸 golden / 手势测试 | 全程 |

## 6. 排期

| 阶段 | 内容 | 人日 |
|---|---|---|
| M1 | P0：工具栏/浮条/结果卡/书库/AI 列表/触控规范 | 3–4 |
| M2 | P1：词级选区 + 手柄 + 震动 + 边缘翻页 + chrome | 4–5 |
| M3 | P1：沉浸/常亮/打开方式/内存回调/后台治理 | 2–3 |
| M4 | 性能：DPI 分档 + 预取调度 + 帧预算测量 | 3–4 |
| M5 | P2 选做（分块渲染 / 音量键 / 亮度） | 按需 |
| **合计** | | **12–16 人日**（单人约 3 周） |

建议顺序：M1 → M2 → M3 → M4，M2 与 M3 可由两人并行。

## 7. 测试与验收

### 7.1 自动化

- **手机尺寸 widget 测试**：`tester.view.physicalSize = 1080×2340`、
  `devicePixelRatio = 3`（≈360×780dp），覆盖书库、阅读器、工具条、结果卡、
  设置页；断言 `tester.takeException()` 为空（专门捕捉 RenderFlex 溢出）。
- **手势测试**：长按选词 → 选中词范围正确；拖手柄扩展；双击选词；
  边缘点击翻页；双指缩放。
- **窄屏模式测试**：宽度 < 700dp 时模式选择器只有单页；双页进度自动降级。
- **内存回调测试**：模拟 `onTrimMemory`，断言缓存清空且当前页保留。
- **Intent 测试**：`ACTION_VIEW` 冷启动 / 热启动各一条（集成测试）。

### 7.2 真机

| 设备 | 重点 |
|---|---|
| 6.1" 1080×2340（60Hz） | 触控目标、选区手柄、键盘遮挡 |
| 6.7" 1440×3216（120Hz） | 刷新率升降、滚动 jank |
| 小屏 720×1280（≈360×640dp） | 工具栏溢出、底部操作栏高度 |
| 平板 1600×2560 | 双页模式、分栏布局不回归 |

### 7.3 验收清单

- [ ] 360dp 宽下所有页面无 overflow 异常
- [ ] 长按选词后工具条完整可见、可点击，不再抛异常
- [ ] 选区有起止手柄，可精确调整
- [ ] 阅读页可全屏沉浸，点击中部切换 chrome
- [ ] 左右边缘点击翻页，翻页有触觉反馈
- [ ] 阅读时屏幕不熄灭，离开后恢复
- [ ] 其他应用可通过"打开方式/分享"导入 PDF 与图片
- [ ] 系统内存紧张后回到阅读页不崩、不重新加载全部缓存
- [ ] 60Hz 设备滚动 jank < 2%，120Hz 设备能稳定跑满
- [ ] 桌面端 `flutter analyze` / `flutter test` / Linux 构建零回归

## 8. 风险

| 风险 | 说明 | 对策 |
|---|---|---|
| 手势冲突 | 长按选词 vs 滚动、双击选词 vs 缩放、边缘翻页 vs 系统返回 | 统一手势表；真机逐项验证；保留"关闭边缘翻页"设置 |
| 底部工具条遮挡正文 | 选中位置靠近底部时 | 工具条出现时内容整体上移（`AnimatedPadding`），或工具条半透明覆盖 |
| 沉浸模式与刘海/手势条 | `immersiveSticky` 下系统条可临时唤出 | 用 `SafeArea` + `MediaQuery.viewPadding` 动态留白 |
| 分块渲染改动大 | 涉及 Rust 渲染入口与新 FFI | 先做 DPI 分档（收益大、改动小），分块列为 P2 |
| 预取抢锁 | pdfium 全局串行 | 调度器只在空闲时预取；实测首帧延迟 |
| OEM 后台限制 | 常亮/刷新率可能被厂商策略覆盖 | 文档注明；设置项可关 |

## 9. 明确不做

- 不做 iPad/平板专属多窗口与分屏（v1 只保证响应式）。
- 不做手势自定义编辑器（固定一套，设置里只提供开关）。
- 不做阅读页横向"仿真翻页"动画（实现成本高，收益低于手柄与 chrome）。
- 不改桌面端任何交互与默认值；所有分叉以 `PlatformCapabilities` 为边界。
