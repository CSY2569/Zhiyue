# ReadApp Flutter UI 设计方案

> 文档版本：v2.0（2026-08-06）
>
> **范围声明**：本方案规范 **Flutter UI 层（Dart / Flutter Desktop）的原生设计**——页面结构、组件、主题、状态、交互行为、资源、文件组织、里程碑。后端（Rust / PDF / OCR / AI / SQLite / `flutter_rust_bridge` 协议契约）不在本方案范围，由 `docs/TECH_ROADMAP.md` 约定。
> 对应章节以 `[FEATURES §x.y]` 形式标注产品需求条目，便于实现与验收。

---

## 1. 总览与设计原则

### 1.1 UI 层职责边界
Flutter UI 层**只负责**：
- 绘制与交互（页面/组件/动画/主题/快捷键）
- 文本层命中选区、图像层标记绘制
- AI 流式渲染（Markdown + LaTeX）
- 标记拼合导出（`PictureRecorder`）

**不负责**（全部在 Rust 侧，UI 仅通过 `flutter_rust_bridge` 调用）：
- PDF 解析渲染（pdfium）、OCR 推理、AI 网络请求、SQLite/FTS5/jieba 数据存取

### 1.2 核心设计原则
- **坐标一律归一化 [0..1]**——选区/标记/笔记/OCR 行都用页面归一化坐标存储，任何缩放下位置正确
- **页面叠加层模型**——每页一个 `Stack`，承载位图、OCR 文本层、高亮层、选区层；浮动元素（工具条/结果卡/笔记框/区域选择器）由顶层 `Overlay` 承载
- **直接状态调用**——所有跨组件"通知"通过 Riverpod provider 状态驱动 + notifier 方法调用，不引入事件总线
- **最小依赖**——能内置即内置（`SliverList` 虚拟化、`LayoutBuilder`、`Shortcuts/Actions`、`InteractiveViewer` 等），第三方仅在生态不可替代时引入

### 1.3 技术选型
| 维度 | 选型 |
|---|---|
| UI 框架 | Flutter Desktop（Linux 首发，Win/mac 可移植） |
| 状态管理 | Riverpod 2（`Notifier` / `AsyncNotifier` / `StreamProvider`） |
| 路由 | `go_router`（书库/阅读器切换 + 弹窗路由） |
| 数据模型 | `freezed` + `json_serializable` |
| 窗口 | `window_manager`（无边框、拖拽区、最小化/最大化/关闭） |
| 文件对话框 | `file_picker` |
| 剪贴板 | `super_clipboard` |
| Markdown | `flutter_markdown`（GFM）+ `flutter_math_fork`（LaTeX） |
| 图像层标记 | 自绘 `CustomPainter`（dart:ui Canvas） |
| 主题 | Material 3 `ColorScheme` + 系统跟随 + settings 持久化 |
| 拖拽归类 | `Draggable` / `DragTarget`（书库分类） |
| 依赖底座 | `flutter_rust_bridge v2`（类型安全 FFI，AI 流式 → `Stream<T>`） |

---

## 2. UI 层总体架构

```
                    lib/main.dart
                        │ runApp(ProviderScope(child: ReadApp()))
                        ▼
              MaterialApp.router (go_router, theme)
              ┌─────────────┴──────────────┐
          /library                       /reader/:bookId
        LibraryScaffold                ReaderScaffold
        ├─ FramelessTitleBar              ├─ FramelessTitleBar (书名居中 + 返回)
        │  (logo + 主题 + 设置 + 窗控)     ├─ ReaderToolbar
        ├─ CategoryRail (左)              ├─ Row[ 侧栏区 | 阅读区 | AiPanel? ]
        └─ BookGrid + LibraryToolbar      │     └─ PageStack (位图+OCR文本层+高亮+选区)
                                           └─ Overlay 层(浮动工具条/结果卡/笔记框/区域OCR)
               ▲
               │
   ThemeController → AppTheme (MaterialData) + 持久化(settings)
```

**全局组件层级**：
- `MaterialApp.router` → `FramelessTitleBar` + 当前路由页面 + 全局 `Overlay`（浮动元素）
- `Router` 仅 3 个核心路由：`/library`、`/reader/:bookId`、`/settings`（dialog 路由）
- 全局快捷键通过根 `Shortcuts` + `Actions` 注册，由 `uiStateProvider` 统一处理

---

## 3. 路由与导航

### 3.1 路由表
```dart
GoRouter(routes: [
  GoRoute(path: '/library',         builder: (_, __) => LibraryScaffold()),
  GoRoute(path: '/reader/:bookId', builder: (_, s) => ReaderScaffold(bookId: s.pathParameters['bookId']!)),
  GoRoute(path: '/settings',        pageBuilder: (_, __) => DialogPage(child: SettingsDialog())),
])
```

### 3.2 跳转约定
- 打开书：`context.go('/reader/$bookId')`（同时 `viewerNotifier.open(bookId)` 初始化位图/页数/进度）
- 返回书库：`context.go('/library')`（同时 `viewerNotifier.close()` 释放缓存）
- 打开设置：`context.push('/settings')`，关闭后由 `SettingsController` 校验保存

---

## 4. 页面设计

### 4.1 `LibraryScaffold` [FEATURES §2]
**布局**：
```
Row([
  CategoryRail(width: 200),                  // 左：分类侧栏（FEATURES 2.8）
  Expanded(Column([
    LibraryToolbar(导入 / 搜索框 / 筛选),     // 顶部工具条
    Expanded(BookGrid),                       // 自适应网格
  ]))
])
```

**BookGrid**：
- `SliverGrid` + `SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, childAspectRatio: 0.7)`
- 空书库：`Center(Column(Icons.menu_book, "导入文档", FilledButton(onPressed: _import)))`

**BookTile（卡片）**：
- `InkWell`，hover 高亮（`MouseRegion` + `AnimatedOpacity` 显示操作按钮）
- 封面：`Image.memory(FRB book.coverBytes(id))` || 类型占位 `Icon(Icons.description / Icons.image)`
- 元数据：标题、页数、类型徽章
- 操作：星标（收藏）、删除（确认弹窗）、拖入分类
- 点击：`context.go('/reader/$id')`；同时 `libraryNotifier.touch(id)` 更新最近打开

**CategoryRail**（分类拖拽归类）：
- 固定列表：全部 / 收藏 / PDF / 图片 / 自定义分类
- 每个分类为 `DragTarget<int>`（接收 bookId）→ `libraryNotifier.assignCategory(bookId, categoryId)`
- 自定义分类：创建/重命名/删除（长按上下文菜单 `MenuController`）

**导入流程**：
- `file_picker` 多选，extensions = `["pdf", "png", "jpg", "jpeg", "webp", "bmp", "gif", "tiff"]`
- `libraryNotifier.import(paths)` → FRB 复制到 `documents/`、生成记录、去重返回

**对应需求**：FEATURES 2.1–2.8

---

### 4.2 `ReaderScaffold` [FEATURES §3, §6]
**布局**：
```
Column([
  FramelessTitleBar(书名居中, 返回书库),
  Expanded(Row([
    if (anySideBarOpen) SideBarPanel(width: 220),  // 缩略图/大纲/笔记 三选N
    Expanded(
      Stack([                                       // 阅读区（位图 + OCR 文本层 + 高亮 + 选区）
        PageStack(...),                              // 主体（PdfPageScroll 或 ImagePageView）
        if (selection != null) SelectionLayer(),
        if (ocrSelecting) RegionSelector(),
      ]),
    ),
    if (aiPanelOpen) AiPanelSide(width: aiPanelWidth),  // 右侧 AI
  ]))
])
```

**浮动 UI（不进入 Row/Scaffold 节点）**：通过根 `Overlay` 挂载：
- `FloatingToolbar`、`ResultCard`、`NoteComposer`、`NotePopup`
- 所有浮动元素位置由 `uiStateProvider` 持有（`Offset`），用 `Positioned` 渲染

---

### 4.3 `SettingsDialog` [FEATURES §6.1]
**结构**：`showDialog` + 自定义 `Dialog`，`StatefulWidget` 自持草稿防丢失
**字段**：
- 通用 AI 配置：`baseUrl` `apiKey` `chatModel`
- 视觉独立配置（可选）：`visionBaseUrl` `visionApiKey` `visionModel`；不填回退通用
- `translateTargetLang`（默认中文，下拉）
- `enableWebSearch`（开关）
- 校验：仅 `apiKey` 非空检查；保存按钮显式 `enabled` 态
- 提交：`settingsProvider.save(draft)` → FRB `set_ai_config`

---

### 4.4 `AiPanelSide` [FEATURES §6.5]
**宽度持久化**：`uiStateProvider.aiPanelWidth`，可拖分隔条调节
**三视图状态机**：
| 状态 | 触发 | 内容 |
|---|---|---|
| `empty` | 无任何线程 | 引导卡（直接提问示例 + 历史为空提示） |
| `historyList` | 顶部历史按钮 | 按动作类型分组的列表，点击切换 |
| `chatThread` | 选中线程 / 新建 | 消息列表 + 输入框 |

**输入框**：
- `TextField(maxLines: null, expands: true)` 自适应高度
- `KeyboardListener`：Enter 发送 / Shift+Enter 换行
- 发送按钮 disabled 当 `input.trim().isEmpty()` 或流式中

---

## 5. 阅读器主体（PDF / 图片）

### 5.1 `PdfPageScroll` [FEATURES §3.1]
**三种模式**（由 `viewerNotifier.mode` 状态切换）：

| 模式 | 容器 | 实现 |
|---|---|---|
| 单页滚动 | `CustomScrollView` + `SliverList` | 每页一 Sliver，`SliverList.builder` 内置虚拟化，按需 `decodeImageFromPixels` 位图 |
| 双页滚动 | `SliverList` 每行 `Row` 包两页 | 行高取两页最大，按 `pagesPerRow=2` |
| 双页翻页 | `PageView.builder` | 步进 2，左页对齐奇数页；`ScrollPhysics` 节流防连翻 |

**位图缓存**：
- LRU 按缩放档位（0.5x / 1x / 2x），上限 ~20 张
- 引擎懒加载（Rust 侧）：不滚动到不渲染

**跳页**：`ScrollController.animateTo(offset, duration, Curves.easeOutCubic)`
- 切换视图模式时，先记录目标页码再切换容器，切换后 `animateTo` 到对应 offset

**缩放**：
- `InteractiveViewer` 包裹每页（手势捏合 + Ctrl+滚轮）
- `Listener(onPointerSignal)`：检测 Ctrl 修饰键 + `PointerScrollEvent` → `viewerNotifier.setScale(newScale)`
- 区间 0.3–4.0，默认 1.2

**进度恢复** [§3.3.4]：
- `viewerNotifier` 内 `Timer?` 防抖 800ms，在 `currentPage` / `scale` 变更后调 FRB `save_progress`
- 打开书时：`get_progress` → `ScrollController` 跳到 `currentRow` 对应 offset

**对应需求**：FEATURES 3.1–3.6

---

### 5.2 `ImagePageView` [FEATURES §7.3]
**单一页位图**（与 PDF 共用 Overlay 路径，仅位图来源不同）：
- `SingleChildScrollView` + `InteractiveViewer`
- 位图：`Image.memory(FRB image.bytes(bookId))` 或 `Image.file`
- 选区 / 标记 / OCR / 区域 OCR / 标注 全流程同 PDF

---

### 5.3 页面叠加层模型（PdfPageCanvas）
**每页 `Stack`（`Positioned.fill`）承载**：
```
Stack[
  RawImage(decoded RGBA from FRB)         // 位图
  IgnorePointer(child: HighlightLayer())  // 高亮/下划线/删除线
  IgnorePointer(child: OcrTextLayer())    // OCR 透明文本层(参与选区命中)
  SelectionLayer(命中选区 + 浮动工具条触发)  // 接收 Pointer 事件
  if (isScanPage && !ocr) ScanOverlay()    // 扫描提示卡
  if (noteHit != null) NotePopup()         // 笔记浮层
]
```
**最重要的是**：选区不再依赖 DOM/Selection API，而是基于 Rust 暴露的"字符盒数据"（每字符页面绝对坐标数组）+ Dart 端 `PointerEvent` 命中算法。

---

## 6. 阅读区叠加层组件

### 6.1 `SelectionLayer`（精确字符级选区）[FEATURES §4.1]
**数据**（Rust 暴露 → Dart `CharBox[]`，含 `pageX, pageY, w, h, char`）
- `PointerDownEvent` → 二分命中最近字符 → 记录选区起点 index
- `PointerMoveEvent` → 沿"字符链表"扩展选区，跨行逐行精确
- 正反向支持：基于起止 index 大小比较确定方向
- 点击行间空隙 / `Esc` → `uiStateProvider.clearSelection()`
- 选区完成后，`uiStateProvider.selection = Selection(rect: lineRects, text: ...)`，触发 `FloatingToolbar` 显示

**视觉**：`CustomPaint` 半透明选中色块 `Color.fromRGBO(82,138,255,0.4)`（由 `Theme` 控制色相，与 extractionColor token 配套）

---

### 6.2 `FloatingToolbar` [FEATURES §4.2]
**实现**：根 `Overlay` + `OverlayEntry` + `Positioned`
**位置策略**：
- 默认位于选区上方 8px
- 上方空间不足 → 翻到下方
- 用户拖动 → `GestureDetector(onPanUpdate)` 更新 `uiStateProvider.toolbarPos`
**按钮集**（9 个）：翻译 / 解释 / 搜索 / 复制 / 高亮 / 下划线 / 删除线 / 笔记 / 区域 OCR
- 用 `Wrap` 防溢出，按钮 = `IconTextButton`（图标 + 文字水平排）
- 点击触发 `aiNotifier.startAction(action, selection)` 或 `annotationNotifier.create(...)`

---

### 6.3 `HighlightLayer` [FEATURES §4.3]
**实现**：`CustomPaint(painter: HighlightPainter(rects, mode), willChange: false)` + `IgnorePointer`
**三种绘制模式**：
- 高亮：`ColorScheme.primary.withOpacity(0.4)` 填色矩形
- 下划线：底边线条（线宽 2px）
- 删除线：中部线条
**坐标**：归一化 `Rect{x, y, w, h}` 传入 painter，按当前 `RenderSize` 乘得到屏幕像素

---

### 6.4 `OcrTextLayer` [FEATURES §7.1.3]
**实现**：`Stack` 导出多个 `Text` 组件，每个 OCR 行一个，透明色，绝对定位
**作用**：
- 不显示文字（`Color.transparent`）
- 参与 `SelectionLayer` 命中：每行的字符盒由 Rust 提供（与文字版 PDF 同一接口）
**坐标**：归一化的 `OcrLine{x, y, w, h, text, confidence}`，按页 RenderSize 还原

---

### 6.5 `ScanOverlay`（扫描提示卡）[FEATURES §7.1.2]
**状态机**（由 `viewerNotifier.scanState` 驱动）：
| 状态 | UI |
|---|---|
| `notScanned` | 顶部徽章 `Icon(Icons.document_scanner)` + "扫描识别" `FilledButton` |
| `scanning` | `CircularProgressIndicator(strokeWidth: 2)` + "正在识别…" |
| `empty` | "未识别到文字" + 引导使用 "区域 OCR"（多模态） |
| `success` | 底部 chip 提示 "可点击区域 OCR 处理数学/外语" |

**驱动**：`PdfToolbar` 上的整页扫描按钮 → `viewerNotifier.scanCurrentPage()` → 状态更新

---

### 6.6 `NotePopup` [FEATURES §4.4]
**实现**：`OverlayEntry` + `Positioned`，触发：点击高亮区域 → `annotationNotifier.findAt(offset)` 定位
**编辑器**：`TextField(maxLines: null)` + 保存/删除按钮
**快捷键**：`Shortcuts/Actions` — Enter 保存、Esc 关闭

---

### 6.7 `RegionSelector`（区域 OCR）[FEATURES §6.6, §7.2]
**实现**：
- `Stack` 顶层 `Positioned.fill` + `GestureDetector(onPanStart/Update/End)`
- `CustomPaint` 绘制矩形选区框 + 半透明蒙版
- 释放：取选区归一化 rect → 调 FRB `ai.vision_stream(bookId, page, rect)` 拿 `Stream<String>`
- **截图由 Rust 完成**：UI 不拷贝 RGBA，避免大图内存峰值
**固定提示词**（FEATURES 6.6.2）：`"分析图片内容，若为纯文本内容，则返回对应中文翻译，若为图片内容，则返回针对图片内容作出的分析，若为数学，则返回该数学内容的解释"`
**结果**：在 `ResultCard` 流式展示

---

### 6.8 `ResultCard` [FEATURES §6.4]
**实现**：`OverlayEntry` + `Card` + `MarkdownBody` 流式
**渲染**：
- `flutter_markdown` `MarkdownBody(data: aiProvider.cardStream, extensionSet: gfm)`
- 数学公式经 `flutter_math_fork` 处理（流式按块边界增量渲染，节流每帧合 chunk）
- 流式光标：`AnimatedOpacity(Duration(milliseconds: 500))` 闪烁
**附加按钮**：复制 / 展开到侧栏 / 关闭 / 拖动
- 拖动：`GestureDetector(onPanUpdate)` 更新 `uiStateProvider.cardPos`
- 展开到侧栏：`aiNotifier.moveCardToPanel()` → `AiPanelSide` 显示，卡片关闭

---

### 6.9 `NoteComposer` [FEATURES §4.4.1]
**触发**：`FloatingToolbar` 的 "笔记" 按钮
**实现**：`OverlayEntry` + `Container` + `TextField(maxLines: null)` + 保存按钮
**快捷键**：Enter 保存（`Shortcuts/Actions`）、Esc 取消

---

## 7. 侧栏组件

### 7.1 `ThumbnailRail` [FEATURES §3.4.1]
**实现**：`ListView.builder`（自带虚拟化），按页生成缩略图 Tile
**位图来源**：FRB `book.thumbnail(bookId, page) -> Uint8List`
**当前页高亮**：`ListenableBuilder` 监听 `viewerNotifier.currentRow`，命中行加 `Border` 边框
**跳页**：`viewerNotifier.goToPage(n)` 直接调用

### 7.2 `OutlineTree` [FEATURES §3.4.2]
**实现**：自递归 `OutlineNodeWidget`，可选用 `ExpansionTile` 或自定义树
**数据**：Rust 通过 pdfium 提取嵌套大纲 + 命名目标解析后的 `pageIndex`
**点击**：`viewerNotifier.goToPage(pageIndex)`
**空大纲**：`Center(Text("无大纲"))`

### 7.3 `NotesRail` [FEATURES §3.4.3, §4.5]
**列表**：`ListView` 按页分组（`SectionHeader` + 标注条目 `Dismissible`）
**操作**：
- 点击条目 → 跳到此页
- 滑删：`Dismissible` + `annotationNotifier.delete(id)`
- 导出：底部按钮组 `ExportButtons`（Markdown / JSON），日到 FRB `export_annotations_markdown/json` 落地到 `file_picker.saveFile()`

**导出规格**（FEATURES 4.5.2–4.5.3）：
- Markdown：`# 阅读标注` → `## 第 N 页` → 🔆 高亮 / ➖ 下划线 / 📝 笔记（含删除线）
- JSON：含坐标与样式，pretty 格式化

---

## 8. 图像层标记 [FEATURES §5.1–5.7]

### 8.1 标记类型与模型
| 类型 | 数据模型 | 绘制方式 |
|---|---|---|
| 画笔 / 手写批注 | `Path`（矢量路径） | `CustomPaint` 增量重绘 |
| 形状 | 几何 model（矩形/椭圆/箭头参数） | `CustomPaint` |
| 便签 / 文本框 | `(position, text, style)` | `Stack` 定位 `Container` + `TextField` |
| 图章 / 签名 | `(imageBytes, position, scale, rotation)` | `Transform` + `Image.memory` |

所有标记用 `freezed` 定义不可变 model，统一字段：`type, normalizedRect, style, content`。

### 8.2 图层管理面板
- `Stack` 内独立 layer；按类型筛选（`AnimatedSwitcher` 切换显隐）
- `Menu` 上下文菜单：单独删除、整体清空、属性编辑

### 8.3 拼合导出 [FEATURES §5.6]
**实现**：`PictureRecorder` + `Canvas`
1. `canvas.drawImage(pageSprite, Offset.zero, Paint)`
2. 遍历标记 → `canvas.drawPath` / `canvas.drawColor` / `canvas.drawImage`
3. `recorder.endRecording().toImage()` → `imageToByteData(format: png)` → 写入文件

不拼合模式：导出标记数据 JSON（`ImageMarkObject[]`）

### 8.4 撤销 / 重做 [FEATURES §5.7]
- `ImageMarkHistory`：`undoStack` + `redoStack`（任何修改入栈、`undo()` 出栈入 redo）
- Ctrl+Z / Ctrl+Shift+Z 由根 `Shortcuts` 统一接入

---

## 9. 主题与样式系统

### 9.1 配色方案
基于 Material 3 `ColorScheme`，由 seed 色 `Color(0xFF5B63E6)`（蓝紫色相）派生：
```dart
ColorScheme.fromSeed(seedColor: Color(0xFF5B63E6), brightness: Brightness.dark/light)
```
**关键色 token 映射**：

| Token | 对应 `ColorScheme` / 主题 |
|---|---|
| `surface` | `ColorScheme.surface` |
| `onSurface` | `ColorScheme.onSurface` |
| `card` / 卡片前景 | `CardTheme.color` / `onSurface` |
| `popover` | `ColorScheme.surfaceContainerHigh` |
| `primary`（蓝紫色相） | `ColorScheme.primary` |
| `onPrimary` | `ColorScheme.onPrimary` |
| `secondary` | `ColorScheme.secondary` |
| `primaryContainer`（次要强调） | `ColorScheme.primaryContainer` |
| `muted` / muted-foreground | `ColorScheme.surfaceContainerLow` + 自定义 mutedText |
| `accent` | `ColorScheme.tertiary` |
| `destructive`（红橙色相） | `ColorScheme.error` |
| `border` | `DividerTheme.color` / `OutlineInputBorder` |
| `ring`（焦点环） | `FocusTheme.color = ColorScheme.primary` |
| `radius` 0.625rem（≈10px） | `ThemeData.cardTheme.shape: RoundedRectangleBorder(BorderRadius.circular(10))` |

### 9.2 主题切换与持久化 [FEATURES §8.2–8.3]
- `ThemeController extends Notifier<ThemeMode>`（Riverpod）
- 持久化：写到 `settings` 表（FRB `settings.set('theme', value)`）
- 启动：读 `settings` 取主题；无值时跟随 `MediaQuery.platformBrightness`
- `MaterialApp.themeMode: controller.themeMode`
- 切换按钮：`IconButton(Icons.dark_mode / Icons.light_mode)`

### 9.3 AI Markdown 样式
`flutter_markdown` 通过 `MarkdownStyleSheet` 定制：
- 字体默认走 `Theme.of(context).textTheme.bodyMedium`
- 代码块：`fontFamily: monospace`，背景 `surfaceContainerLow`，圆角 6
- 表格：`Table` + 边框 `border` color
- 块引用：左侧 3px `primary` 边框

### 9.4 排版与字体
- **不引入新字体**（占用最小化目标）：全部走系统默认
- 唯一例外：AI Markdown 代码块 `fontFamily: monospace`（Flutter 自带 `monospace`）

---

## 10. 状态管理（Riverpod）

### 10.1 Providers 拆分
| Provider | 类型 | 状态/职责 |
|---|---|---|
| `themeController` | `Notifier<ThemeMode>` | 亮/暗 + 持久化 |
| `uiStateProvider` | `Notifier<UiState>` | view 之外的瞬态 UI：浮动元素显隐/位置、AI 面板宽、selection、ocrSelecting、noteComposer |
| `libraryNotifier` | `Notifier<LibraryState>` | 书目列表 / 导入 / 删除 / 收藏 / 分类（CRUD） |
| `viewerNotifier` | `Notifier<ViewerState>` | 当前书、numPages、currentPage、scale、mode、outline、scanState、pageSizes map、LRU 位图缓存指针 |
| `annotationNotifier` | `Notifier<AnnotationState>` | 标注 CRUD / 导出 / `findAt(offset)` |
| `aiNotifier` | `Notifier<AiState>` | threads list、activeThreadId、卡片显隐、cardPos、followUp 路由 |
| `cardStreamProvider` | `StreamProvider<String>` | 卡片流式文本 |
| `threadStreamProvider`（per threadId） | `StreamProvider<String>` | 当前对话线程流 |
| `settingsProvider` | `Notifier<AiConfig>` | BYOK 配置读取 / 草稿托管 |
| `imageMarkNotifier` | `Notifier<ImageMarkState>` | 图像层标记列表 + undo/redo |

### 10.2 跨组件通信约定
- **不使用任何事件总线 / `EventChannel` / `MethodChannel` 自定义事件**，所有"通知"经 Riverpod 状态广播
- **AI 流式**：Rust 侧 FRB `Stream<AiChunk>` 被 `StreamProvider` 包装，UI 监听状态消费

---

## 11. 全局交互（快捷键 / 拖动 / 滚轮）

### 11.1 全局快捷键 [FEATURES §8.6–8.10]
在根 `MaterialApp` 之上挂 `Shortcuts` + `Actions`：
| 快捷键 | 动作 |
|---|---|
| `Esc` | `uiStateProvider.clearSelection()` + 隐藏结果卡 |
| `Ctrl+滚轮` | `viewerNotifier.setScale(scale ± 0.1)` |
| `双页翻页模式滚轮` | 翻页（节流 250ms）`viewerNotifier.goNextPair()` |
| `Enter`（AI 输入框） | 发送 |
| `Shift+Enter`（AI 输入框） | 换行 |
| `Ctrl+Z / Ctrl+Shift+Z`（图像层标记模式） | undo / redo |
| `Ctrl+S` | 导出标注（最近一次格式） |

### 11.2 Ctrl+滚轮缩放
根 `Listener(onPointerSignal)`：过滤 `PointerScrollEvent`，判断 `HardwareKeyboard.instance.isControlPressed` → `viewerNotifier.setScale`

### 11.3 浮动元素拖动
所有浮动 UI（`FloatingToolbar` / `ResultCard` / `NotePopup`）位置存在 `uiStateProvider`，由 `GestureDetector(onPanStart/Update/End)` 更新 `Offset`

---

## 12. 资源

### 12.1 图标
全部使用 **Material Icons**，集中在 `lib/core/app_icons.dart` 统一导出（方便后期切换自定义图标字体）。
**核心映射**：
| 用途 | 图标 |
|---|---|
| 品牌 / 书库 | `Icons.menu_book` `Icons.book` |
| 设置 | `Icons.settings` |
| 主题切换 | `Icons.light_mode` / `Icons.dark_mode` |
| 窗口控制 | `Icons.minimize` / `Icons.crop_square` / `Icons.close` |
| 复制 / 发送 | `Icons.copy` / `Icons.send` |
| 导出 | `Icons.description`（MD）/ `Icons.code`（JSON）/ `Icons.download` |
| 卡片操作 | `Icons.add` / `Icons.star_border` / `Icons.delete` / `Icons.image` |
| 加载 | `CircularProgressIndicator(strokeWidth: 2)`（替代"动画图标"） |
| 工具条 | `Icons.zoom_in/out`, `Icons.chevron_left/right`, `Icons.view_column`（双页） |
| 侧栏 | `Icons.account_tree`（大纲）/ `Icons.view_sidebar`（缩略图）/ `Icons.list_alt`（笔记） |
| OCR | `Icons.document_scanner` |
| 标记 | `Icons.brush` / `Icons.format_underline` / `Icons.sticky_note_2` |
| AI | `Icons.translate`, `Icons.search`, `Icons.chat_bubble_outline`, `Icons.auto_awesome` |
| 状态 | `Icons.error_outline` / `Icons.edit` / `Icons.check` |

### 12.2 运行时资源
- **书籍封面**：FRB `book.coverBytes(bookId) -> Uint8List` → `Image.memory`
- **无封面占位**：类型徽标（`Container` + `Icon(Icons.description / Icons.image)`）
- 不内置任何字体文件、图标字体；只依赖 Flutter SDK 与 Material Icons

### 12.3 Markdown + LaTeX
- `flutter_markdown` `MarkdownBody` + `ExtensionSet.gitHubFlavored`
- `flutter_math_fork` 处理 `$...$` / `$$...$$`（数学 OCR 场景必备）

### 12.4 动画 / 过渡
| 场景 | 实现 |
|---|---|
| Dialog / Menu 弹出（淡入 + 缩放） | `showDialog` 默认 + `FadeTransition` + `ScaleTransition`（如默认不够，包一层 `AnimatedSwitcher`） |
| 加载中 | `CircularProgressIndicator(strokeWidth: 2)` |
| 流式光标（结果卡 / 对话末尾） | `AnimatedOpacity(Duration(milliseconds: 500))` 闪烁 |
| 卡片 hover 显示操作 | `MouseRegion(onEnter/Exit)` + `AnimatedOpacity` |
| 列表跳页平滑滚动 | `ScrollController.animateTo(offset, Duration(milliseconds: 250), Curves.easeOutCubic)` |
| 主题切换 | `MaterialApp.themeMode` 改变即重渲，无显式过渡（如需 `AnimatedTheme` 包装） |

---

## 13. UI 文件结构

```
lib/
├── main.dart                       # runApp(ProviderScope(child: ReadApp()))
├── app/
│   ├── app.dart                    # MaterialApp.router
│   ├── router.dart                 # go_router 路由表
│   └── theme/
│       ├── app_theme.dart          # ThemeData build + ColorScheme.fromSeed
│       └── theme_controller.dart    # 亮/暗 + settings 持久化
├── core/
│   ├── app_icons.dart              # Material 图标统一导出
│   ├── shortcuts.dart              # 全局 Shortcuts/Actions 定义
│   └── frb_facade.dart             # flutter_rust_bridge 调用 facade（按域聚合）
├── data/                           # freezed 模型
│   ├── book.dart, reading_progress.dart
│   ├── annotation.dart, ai_thread.dart, ai_message.dart
│   ├── ocr_line.dart, char_box.dart
│   ├── selection.dart, region_rect.dart
│   └── image_mark.dart
├── state/                          # Riverpod providers
│   ├── ui_state.dart
│   ├── library_notifier.dart
│   ├── viewer_notifier.dart
│   ├── annotation_notifier.dart
│   ├── ai_notifier.dart
│   ├── image_mark_notifier.dart
│   └── settings_provider.dart
├── ui/
│   ├── shell/
│   │   ├── frameless_title_bar.dart
│   │   └── window_controls.dart
│   ├── library/
│   │   ├── library_scaffold.dart
│   │   ├── library_toolbar.dart
│   │   ├── book_grid.dart
│   │   ├── book_tile.dart
│   │   └── category_rail.dart
│   ├── reader/
│   │   ├── reader_scaffold.dart
│   │   ├── reader_toolbar.dart
│   │   ├── pdf_page_scroll.dart           # 三模式滚动容器
│   │   ├── pdf_page_canvas.dart            # 单页位图 + 叠加层 Stack
│   │   ├── image_page_view.dart
│   │   ├── overlay/
│   │   │   ├── selection_layer.dart
│   │   │   ├── floating_toolbar.dart
│   │   │   ├── result_card.dart
│   │   │   ├── note_composer.dart
│   │   │   ├── note_popup.dart
│   │   │   ├── region_selector.dart
│   │   │   ├── highlight_layer.dart
│   │   │   ├── ocr_text_layer.dart
│   │   │   ├── scan_overlay.dart
│   │   │   └── image_mark_layer.dart      # 图像层标记绘制
│   │   └── sidebars/
│   │       ├── thumbnail_rail.dart
│   │       ├── outline_tree.dart
│   │       └── notes_rail.dart
│   ├── ai/
│   │   └── ai_panel.dart
│   ├── settings/
│   │   └── settings_dialog.dart
│   └── search/
│       └── fulltext_search_view.dart       # M6
└── widgets/                              # 通用样式 widget
    ├── app_button.dart                  # variant/size API
    ├── app_input.dart
    ├── app_textarea.dart
    └── app_label.dart
```

**分层约定**：
- `app/`：应用级 wiring（root widget、router、theme）
- `core/`：跨域通用工具
- `data/`：纯模型（无 UI 依赖、无 FRB 依赖）
- `state/`：Riverpod providers（持有状态 + 调 FRB）
- `ui/`：按页面域分组（shell / library / reader / ai / settings / search）
- `widgets/`：通用 widget（领域无关）

---

## 14. UI 里程碑

按 `docs/TECH_ROADMAP.md` 的 M1–M6 同步推进；每个里程碑给出 UI 可交付验收状态，FRB 接口先以 mock provider 验收，再切换真接口。

### M1 — UI 骨架 + 书库 [FEATURES §2]
- `main.dart` + `ProviderScope` + `MaterialApp.router`
- `AppTheme` + `themeController` + 亮/暗切换 + 持久化
- `FramelessTitleBar`（拖拽 + 窗控 + 主题 + 设置）
- `LibraryScaffold` + `LibraryToolbar` + `BookGrid` + `BookTile` + 空状态 + 导入 + 收藏 + 删除 + 检索/筛选
- `CategoryRail` + `Draggable` 拖拽归类 + 右键菜单批量归类
- `go_router`：`/library` ↔ `/reader/:id` ↔ `/settings`

### M2 — 阅读器主体 [FEATURES §3.1–3.6]
- `PdfPageScroll` 三模式（单页滚动 / 双页滚动 / 双页翻页）+ 虚拟化
- `ReaderToolbar`（侧栏切换、页码、缩放、模式、扫描、区域 OCR、AI 面板）
- `ThumbnailRail` / `OutlineTree` / `NotesRail`（基础）
- `ImagePageView` 共用 overlay 路径
- 进度恢复（防抖 800ms 持久化）

### M3 — 选区与文本层标记 [FEATURES §4]
- `SelectionLayer`（字符盒命中）
- `FloatingToolbar`（9 按钮 + 自动避让 + 可拖动）
- `HighlightLayer`（高亮 / 下划线 / 删除线）
- `NotePopup` / `NoteComposer`
- `NotesRail` 完成（导出 Markdown / JSON）

### M4 — AI 与区域 OCR [FEATURES §6, §7.2]
- `AiPanelSide`（三视图状态机 + 流式 Markdown + LaTeX）
- `ResultCard`（可拖动 + 展开 + 流式光标）
- `SettingsDialog`（BYOK + 视觉独立配置）
- `RegionSelector`（拖框 + 提示词绑定）

### M5 — 图像层标记 + 整页 OCR [FEATURES §5, §7.1]
- 画笔 / 形状 / 便签 / 图章 CustomPainter
- 图层管理面板（按类型筛选）
- 拼合导出（`PictureRecorder`）
- `ScanOverlay` 4 状态机 + 整页扫描
- Undo / Redo（`imageMarkNotifier`）

### M6 — 全文搜索 + 打磨 [FEATURES §3.5]
- `FulltextSearchView`（输入框 + 命中页列表 + 上下文摘要 + 跳页）
- 页内命中词高亮
- 性能 / 占用打磨（动画曲线、滚动观察、首字延迟、占位符策略）

---

## 15. UI 设计风险与对策

| 项 | 风险 | 对策 |
|---|---|---|
| 高 DPI 渲染对齐 | 不同 `devicePixelRatio` 下文本层像素偏差 | 位图与字符盒坐标都按归一化存储；渲染时一次性乘 `MediaQuery.devicePixelRatio` |
| 选区命中精度 | Dart 端无现成 SelectionArea 适用于自绘场景 | Rust 暴露字符盒数据 → Dart 二分命中算法，跨行逐行精确 |
| `Stack` 多层叠加（位图/高亮/OCR/选区/扫描） | 双页模式时多层对齐复杂 | 统一"每页一个 `Stack`"基础单位，并 `Positioned.fill` 容纳 Highlight/Ocr/Selection；浮动 UI 走根 `Overlay` |
| 模式切换保持阅读位置 | 单↔双页切换易跳页 | 切换前记录 `currentPage`，切换后 `ScrollController.animateTo` 至对应 offset |
| 侧栏当前页同步 | Flutter 无 IntersectionObserver | `ScrollController` 监听 offset 反推 `currentRow` |
| `window_manager` Linux 兼容 | 拖拽/无边框 Linux 行为差异 | 锁定 `window_manager` 稳定版本，备选设置项"使用系统标题栏" |
| AI 流式 Markdown + LaTeX | `flutter_math_fork` 每字符更新昂贵 | 节流：每帧合并 chunk；按 Markdown 块边界增量重建 |
| 双页翻页滚轮连翻 | Linux 高反馈率滚轮易触发多次翻转 | `Timer` 节流 250ms 内忽略后续滚动 |
| 设置对话框草稿丢失 | `showDialog` 关闭即 dispose | `StatefulWidget` 自持 draft，仅在用户确认"保存"或"取消"时执行 |
| 选中色与主题脱节 | 硬编码蓝色不被 dark mode 影响 | `SelectionColor.from(ColorScheme.primary.withOpacity(0.4))` |
| 字体 fallback（LaTeX/Monospace） | 某些 Linux 缺默认 monospace | `flutter_math_fork` 自带；如缺测试用 `RobotoMono` 字体包 |

---

## 16. 不在本方案范围
- **后端 Rust 实现**：PDF 渲染（pdfium-render）、OCR（rapidocr-core）、AI（async-openai）、SQLite（rusqlite + FTS5 + jieba-rs）、`flutter_rust_bridge` 类型生成
- **业务表 schema**：详见 `docs/FEATURES.md` §9.1
- **接口契约**：FRB 接口命名 / Stream 协议 / Rust 端结构体定义
- **打包分发**：Linux / Win / macOS 应用打包、AppImage / dmg / msi

上述均由 `docs/TECH_ROADMAP.md` 统筹规划。

---

## 17. 验收 Checklist（每里程碑）

每个里程碑完成后，按以下维度对照 FEATURES.md 验收：
- [ ] **视觉**：色板 / 字号 / 间距 / 圆角对齐 Material 3 tokens
- [ ] **交互**：键鼠 / 拖动 / 快捷键 / 主题切换 与本方案定义一致
- [ ] **性能**：滚动 ≥ 60fps、AI 首字延迟低、OCR 引擎懒加载
- [ ] **功能**：FEATURES.md 条目逐条勾选（标注"已实现/已交付验收"）
- [ ] **结构**：文件位置与本方案 §13 一致；状态归属与本方案 §10 一致

（完）