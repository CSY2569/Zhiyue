# ReadApp 技术路线文档

> 文档版本：v2.1（2026-08-06）
>
> **路线决策**：Flutter Desktop（UI）+ Rust 核心层，**完全重做、零参考**——不迁移、不阅读、不参考现有 Tauri/WebView 代码。
> 目标：实现 [docs/FEATURES.md](FEATURES.md) 中全部任务需求（含书籍分类、**本地 OCR 精准优先**）；在满足功能的前提下**占用最小化、性能最大化**。
> 依据边界：需求与规格只以 FEATURES.md 为准；技术参数（如 OCR 预处理）以官方模型文档与公开规范为准。

---

## 1. 架构总览

```
┌────────────────────────────────────────────────┐
│ Flutter Desktop（UI 层，Dart）                  │
│  书库（分类/收藏/检索） 阅读区  标记层  侧边栏    │
│  AI 面板 / 设置 / 标题栏                        │
│  状态管理：Riverpod   模型：freezed             │
└───────────────────┬────────────────────────────┘
                    │ flutter_rust_bridge v2（类型安全 FFI）
                    │ 命令调用 → Rust；AI 流式 → Stream<T>
┌───────────────────┴────────────────────────────┐
│ Rust 核心层（无 UI，全部重活）                    │
│  PDF（pdfium-render）   OCR（rapidocr-core）     │
│  AI（async-openai）     SQLite + FTS5 + jieba   │
│  数据模型 / 命令接口（FRB 导出）                 │
└────────────────────────────────────────────────┘
```

**分工原则**：所有重活与数据在 Rust 侧（PDF 解析渲染、OCR、AI 网络、数据库、搜索索引）；Flutter 只做绘制与交互（选区命中、标记绘制、流式渲染），拼合导出也在 Flutter 侧完成。

---

## 2. 技术选型（零复用，全部从生态新选）

### 2.1 UI 层（Dart / Flutter）

| 模块 | 选型 | 理由 / 说明 |
|---|---|---|
| UI 框架 | **Flutter Desktop**（Linux 首发，Win/mac 可移植） | 自绘引擎（Impeller），无 WebView 内存负担；矢量绘制能力强 |
| 状态管理 | **Riverpod** | 声明式、可测试 |
| 视图组织 | go_router | 书库/阅读器切换 + 弹窗路由 |
| 数据模型 | **freezed + json_serializable** | 标注/标记/OCR 行的不可变模型 |
| Markdown 渲染 | **flutter_markdown**（GFM）+ **flutter_math_fork** | AI 回答的 Markdown + LaTeX 公式渲染 |
| 窗口 | **window_manager** | 无边框、拖拽区、最小化/最大化/关闭 |
| 文件对话框 | **file_picker** | Flutter 生态，Linux 走 GTK/zenity |
| 剪贴板 | **super_clipboard** | 维护活跃 |
| 快捷键 | Flutter 内置 Shortcuts/Actions + Listener | Esc、Ctrl+滚轮、Enter 发送框架内解决，零第三方 |
| 图像层标记 | **dart:ui Canvas / CustomPainter 自绘** | 画笔/形状/便签/图章原生矢量，无第三方 |
| 拼合导出 | **PictureRecorder → ui.Image → PNG** | Flutter 侧完成 |
| 主题 | Material 3 + 系统跟随 + settings 持久化 | 需求 8.2 / 8.3 |
| 拖拽归类 | Flutter 内置 Draggable / DragTarget | 书库分类拖拽归类 |

### 2.2 Rust 核心层

| 模块 | 选型 | 理由 / 说明 |
|---|---|---|
| 后端形态 | 纯 lib crate + **flutter_rust_bridge v2** | 无框架；FRB 生成类型安全绑定与流式回调 |
| PDF 渲染/文本 | **pdfium-render** | 渲染位图 + 文本提取 + **字符盒坐标**（选区/文本层标记数据基础） |
| OCR | **rapidocr-core**（RapidAI 官方） | 开箱 det/cls/rec 完整管线 + 后处理 + 取消令牌（基于 ort）；**默认高精度模式（PP-OCRv4 server 版 det/rec，fp32）**，设置可切换快速模式（mobile + int8，~5MB） |
| AI 客户端 | **async-openai**（备选：reqwest 手写） | 自定义 base_url、流式 chat、多模态；兼容 DeepSeek / Kimi / 通义 |
| 数据库 | **rusqlite**（bundled，WAL）+ **FTS5** | 全文搜索用内置 FTS5 |
| 中文分词 | **jieba-rs** | 中文检索质量（FTS5 原生分词对中文只有逐字切分）；词典 ~5MB 可换精简版 |
| 图片处理 | **image** crate | 封面缩略图、备用拼合路径 |
| 日志/错误 | **tracing** + anyhow / thiserror | 结构化日志 |
| 测试 | cargo test + flutter integration_test | 前后端分层测试 |

---

## 3. 关键子系统设计

### 3.1 PDF 渲染管线（需求 3.1-3.6）
- Rust 按页渲染为 RGBA 位图 → FRB 传 `Uint8List` → `ui.decodeImageFromPixels` 上传 GPU 纹理
- **多级位图缓存**：按缩放档位缓存（0.5x / 1x / 2x，LRU 上限 ~20 张），缩放不重渲染
- **虚拟化**：ListView.builder 只构建视口附近页；双页模式行内 Row 布局
- 三种视图模式、页码、进度恢复（需求 3.1-3.3）

### 3.2 文本层与精确选区（需求 4.1）
- 文字版：pdfium 提取文本项 + **字符盒**（每字符页面坐标）
- 扫描版：OCR 行矩形注入"隐形文本层"（内存中的文本-坐标映射，无 DOM）
- 选区：按下/移动做**最近字符命中**，支持正反向；跨行逐行精确；坐标即数据，无排版测量误差

### 3.3 文本层标记（需求 4.3-4.5）
- 高亮 / 下划线 / 删除线 = 矩形几何（归一化坐标），CustomPaint 直接绘制
- 笔记弹窗、标注侧栏、Markdown / JSON 导出

### 3.4 OCR 集成（需求 7.1-7.3，**精准优先**）
- **rapidocr-core** 推理，**默认高精度模式**：server 版 det/rec（fp32）+ **原始分辨率输入**（短边 ≥1280px，取 PDF 页面渲染/图片原始分辨率，不使用屏幕截图）；快速模式（mobile + int8）可在设置切换
- **预处理增强**：灰度化 / 自适应对比度（CLAHE）/ 锐化 / 去噪，改善低质量扫描件
- **四边形文本框**：det 输出四点多边形 → 旋转矫正（仿射变换）后送入 rec，非轴对齐倾斜文本亦可精准识别；180° 方向分类 + 90° 旋转检测矫正
- 扫描页检测 = pdfium 文本提取为空 → 提示条 → 扫描 → 行矩形注入选区系统
- 按 (bookId, page) 缓存（SQLite + 内存）；引擎懒加载；取消令牌支持
- 图片阅读器与扫描页共用同一渲染/选区/标记管线

### 3.5 图像层标记（需求 5.1-5.7）
- 画笔 / 形状：Pointer 事件 → 矢量路径（CustomPainter 增量重绘）
- 便签：定位 + 文本字段组件；图章 / 签名：位图 + 变换矩阵（缩放 / 旋转）
- 图层模型：标记对象列表（类型 / 归一化坐标 / 样式），按类型筛选
- 拼合导出：PictureRecorder 重绘页面位图 + 标记 → PNG（Flutter 侧）

### 3.6 AI 流式（需求 6.1-6.6）
- **async-openai**：自定义 base_url / 流式 chat / 多模态 vision；FRB Stream 推送 chunk → Riverpod 状态 → Markdown（含 LaTeX 公式）流式渲染
- 取消：async-openai 的 abort / 自定义取消令牌
- 历史持久化：`ai_history` 表读写（需求 6.5.4）

### 3.7 数据层与搜索（需求 9、3.5）
- SQLite（WAL）：表结构按 FEATURES 9.1（含 `categories` 分类表、`page_text_index`、`ai_history`）
- 全文搜索：文字版 pdfium 提取文本 / 扫描版 OCR 文本 → **jieba-rs 分词** → FTS5 索引；命中页列表 + 上下文摘要 → 跳转定位

### 3.8 书库与分类（需求 2）
- 分类：独立 `categories` 表（名称 / 排序 / 创建时间），`books.category_id` 关联；创建 / 重命名 / 删除（删除时书籍回退为未分类）
- 书架侧栏：全部 / 收藏 / PDF / 图片 / 各自定义分类；**Draggable 拖拽归类** + 右键/菜单批量归类
- 检索与筛选联动分类（需求 2.7）

### 3.9 窗口与主题（需求 8）
- 无边框窗口 + 自绘标题栏（拖拽区、居中书名、最小化 / 最大化 / 关闭）
- 主题存 settings 表，启动恢复

---

## 4. 性能与占用目标（量化）

| 指标 | 目标 |
|---|---|
| 运行时内存 | 基线 **250-400MB**；OCR 引擎懒加载：快速模式 +35MB（mobile int8），高精度模式 +200-300MB（server fp32） |
| 安装体积 | **25-45MB**（Flutter AOT ~10MB + pdfium ~5-10MB + jieba 词典 ~5MB + OCR 模型：快速 ~5MB / 高精度 ~90MB + 业务代码） |
| 启动时间 | **<1s** |
| 整页 OCR | 高精度模式 ≤ 3s / 页（CPU，原始分辨率）；快速模式 ≤ 0.5s / 页 |
| 滚动 / 翻页 | 60fps（GPU 纹理 + 虚拟化） |
| AI 流式 | 逐字渲染（FRB Stream，事件按帧合并） |
| 首次索引构建（全文搜索） | 大文档按页后台增量构建，不阻塞阅读 |

---

## 5. 需求覆盖映射（FEATURES.md → 方案 → 里程碑）

| 需求章节 | 实现方案 | 里程碑 |
|---|---|---|
| 2 书库管理（含 2.8 分类） | 3.7 / 3.8 | M1 |
| 3 阅读器（模式/缩放/翻页/侧栏/搜索/性能） | 3.1 渲染管线 + 3.7 索引 | M2、M6（搜索） |
| 4 文字选择与文本层标记 | 3.2 字符盒选区 + 3.3 标记 | M3 |
| 5 图像层标记 | 3.5 CustomPaint 矢量层 | M5 |
| 6 AI 功能 | 3.6 async-openai 流式 | M4 |
| 7 OCR 双引擎 + 图片阅读器 | 3.4 rapidocr-core 集成 | M4（区域 OCR）、M5（整页） |
| 8 界面与窗口 | 3.9 | M1（骨架）、M3（拖拽浮层） |
| 9 数据与存储 | 3.7 | M1 |
| 10 非功能需求 | 第 4 节量化目标 | 全程 |

---

## 6. 里程碑计划（单人，共约 5-6 个月）

| 里程碑 | 内容 | 预估 |
|---|---|---|
| **M1 骨架与书库** | Flutter 工程 + FRB 管道 + SQLite（含 categories 表）+ 书库（导入/网格/收藏/删除/**分类管理**/**拖拽归类**/检索筛选）+ 无边框标题栏 + 主题 | 3 周 |
| **M2 PDF 管线** | pdfium 渲染 + 纹理显示 + 虚拟滚动 + 三模式 + 缩放/翻页 + 进度恢复 + 侧栏（缩略图/目录） | 3 周 |
| **M3 选区与文本层标记** | 字符盒选区 + 工具条 + 高亮/下划线/删除线 + 笔记 + 标注侧栏 + 导出 | 3 周 |
| **M4 AI 与区域 OCR** | async-openai 流式 + 卡片/侧边栏 + 多模态区域 OCR + 设置 + 历史持久化 | 3 周 |
| **M5 图像层标记与整页 OCR** | 画笔/便签/图章/形状 + 图层管理 + 拼合导出 + rapidocr 整页扫描（**高精度/快速双模式**、原始分辨率输入、预处理增强、四边形矫正）+ 隐形文本层 + 图片阅读器 | 4-5 周 |
| **M6 全文搜索 + 打磨** | FTS5 + jieba 索引（文字版 PDF + OCR 已扫描页；**导入后后台异步预构建 + 扫描成功增量入索引**；图片书不建索引）+ 书库全局搜索 UI（命中书/页/摘要 + 跳转定位）+ 页内命中词高亮 + 性能/体积调优（LRU 缓存、LTO、内存分析、启动优化） | 3 周 |

每里程碑以 FEATURES.md 对应编号验收；旧 Tauri 代码**不迁移**，仅作行为参考（选区交互、虚拟滚动算法等可对照实现）。

---

## 7. 风险与对策

| 风险 | 对策 |
|---|---|
| pdfium 渲染质量 / 分发 | Chromium 同源引擎，渲染成熟；libpdfium.so 预编译随包分发（BSD-3） |
| 位图传输内存峰值（一页 ~9MB RGBA） | 分块传输 / 共享内存；LRU 上限防累积 |
| rapidocr-core crate 较年轻（API 变动） | 锁定版本 + 备选自研 ort 管线（PP-OCRv4 流程已明确） |
| **精准优先与"占用小"目标冲突**（server 模型体积 ~90MB / 内存 +200-300MB） | 默认高精度模式满足精准需求（7.1.9）；快速模式（mobile + int8）设置一键切换；模型按需下载、引擎懒加载，不扫描不占内存 |
| async-openai 对国产服务商多模态格式适配 | 备选：reqwest 手写请求体（成本低） |
| jieba 词典体积 | 精简词典 / 按需加载 |
| Flutter Linux 桌面生态缺口 | 文件对话框 file_picker；窗口 window_manager；异常场景有社区方案 |
| 完全重写工作量 | 里程碑按模块验收；验收规格以 FEATURES.md 条目为准；行为问题通过原型迭代收敛 |

---
