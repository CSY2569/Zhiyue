# RBWA 实施状态与后续开发方向

> 文档版本：v1.0（2026-08-08）
> 配套文档：[FEATURES.md](FEATURES.md)（需求规格）· [TECH_ROADMAP.md](TECH_ROADMAP.md)（技术路线）· [ARCHITECTURE.md](ARCHITECTURE.md)（架构）

## 1. 项目概况

**RBWA（Read Book With AI）**：原生 AI 集成的本地阅读器。阅读 PDF（文字版 / 扫描版）与图片文件，选中文字即可翻译、解释、搜索；支持文本层与图像层标记；内置本地 OCR 与多模态 OCR。

- **架构**：Flutter Desktop（UI/绘制）+ Rust 核心层（PDF/OCR/AI/DB/搜索），flutter_rust_bridge v2 类型安全 FFI，AI 流式经 Stream 推送
- **数据**：SQLite（WAL）+ FTS5 全文索引 + jieba 中文分词
- **OCR**：rapidocr-core（PP-OCRv4 det/cls/rec，ONNX Runtime 静态链接，完全离线）
- **AI**：OpenAI 兼容协议（BYOK，可配 DeepSeek/Kimi/通义等），多模态识图
- **目标平台**：Linux 桌面
- **开发模式**：单人开发，里程碑制，零参考重写

## 2. 里程碑实施进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 骨架 | 工程脚手架 + FRB 管道 + SQLite schema + UI 空壳 | ✅ 完成 |
| M1 书库 | 导入 / 网格 / 收藏 / 删除 / 检索筛选 / **分类管理（增删改+拖拽归类）** / 封面缩略图 / 无边框标题栏 / 主题持久化 | ✅ 完成 |
| M2 PDF 管线 | pdfium 渲染位图→GPU 纹理 / 虚拟滚动 / 三视图模式（单页、双滚动、双页）/ 缩放 / 翻页 / 进度恢复 / 侧栏（目录树、缩略图轨） | ✅ 完成 |
| M3 选区与文本层标记 | 字符盒精确选区（正反向、跨行）/ 高亮 / 下划线 / 删除线 / 笔记弹窗 / 标注侧栏 / Markdown + JSON 导出 | ✅ 完成 |
| M4 AI 与识图 | 流式对话（Markdown + LaTeX 渲染）/ 提示词模板（内置 + 自定义保存）/ 设置（模型 / Key / 温度）/ 历史持久化 / **自由截图→多模态识图** | ✅ 完成 |
| M5 整页 OCR 与图像层标记 | 扫描页自动检测 / 整页扫描（高精度 server + 快速 mobile 双模式）/ 隐形文本层（可选中）/ 按页缓存 / 引擎懒加载 / 图片文件阅读 / 画笔 / 便签 / 图章 / 形状 + 撤销重做 / 拼合导出 | ✅ 完成 |
| M6 全文搜索 | FTS5 + jieba 分词 / 文字版 PDF + OCR 已扫描页索引 / 导入后后台预构建 + 扫描成功增量入索引 / 失败终态标记（防重试循环）/ 书库全局搜索（命中书/页/摘要 + 跳转）/ 页内命中词高亮 | ✅ 完成 |
| 7.1.10–7.1.12 OCR 精度三件套 | 图像预处理增强（低对比度拉伸 / 模糊锐化，干净页零副作用）/ 90° 页面自适应重扫矫正（坐标映射回原图）/ 180° cls 内置矫正 / 四边形透视矫正验证 | ✅ 完成（2026-08-08） |
| 7.1.6 置信度展示 | 低置信度 OCR 行（confidence < 0.8）页面半透明标记 + 扫描条计数提示 | ✅ 完成（2026-08-10） |
| 7.1.7 OCR 手动修正 | 点击低置信度行编辑文本 → 回存 OCR 缓存 → 重入全文搜索索引 → 文本层与计数同步刷新 | ✅ 完成（2026-08-10） |
| M7 对照阅读（双语阅读） | 阅读页「对照阅读」按钮 → 阅读区内 50/50 左右分栏（左原文 / 右译文，随翻页联动、视图模式自动切单页并恢复）/ 段落级抽取（基线聚行+断字还原+噪声剔除+四信号公式识别，全程独立 pdfium 句柄）/ DeepL + OpenAI 兼容翻译（严格对齐、占位符防伪造与回填校验、限流退避、术语表）/ 三种翻译方式（整本 / 随进度 / 手动）+ Dart 队列编排与续传 / 术语表与固定保留设置 / 按需导出译文 PDF（1..N 顺序、占位页、原页锚点、原页尺寸、版式保留覆盖、可选中文本、运行时字体子集化）/ 2GB LRU + 删书级联 | ✅ 完成（2026-09-11，09-14 体验改版） |

## 3. 当前技术状态（关键数据）

| 指标 | 实测 |
|---|---|
| 整页 OCR 性能（release，A4 合成页） | 快速 ~0.4s/页，高精度 ~1.8s/页（目标 ≤0.5s / ≤3s） |
| 空闲内存（release，未扫描时） | RSS ~294MB（OCR 引擎懒加载，扫描时按模式 +35~300MB） |
| 存储占用 | ~790MB（文档 570 + 模型 210 + DB ~9.5MB 含搜索索引 2.9MB） |
| 全文检索性能 | FTS5 查询 <10ms，命中高亮 <1ms/帧（缓存复用） |
| 测试规模 | Rust 单测 130 个 + OCR e2e 6 个（真实模型，`--ignored`）+ 集成 2 个 + Flutter widget 测试 202 个，全部通过 |
| 静态检查 | clippy 零警告；flutter analyze 零问题 |

### 3.1 今日实现：OCR 精度三件套（54ae7ae）- **7.1.10 预处理增强**：识别前按油墨亮度中位数（>80 判"墨是灰的"）触发百分位拉伸、按强边缘比例（<1e-4 判"边缘是软的"）触发 unsharpen 锐化。门限为**密度无关**指标，稀疏文本页不会误触发；干净页像素级不变
  - 过程中修复一个隐蔽 bug：原 1%/99% 百分位指标在油墨覆盖率 <1% 的页面上会把整页拉成纯黑（1% 分位落在白底上）
- **7.1.12 90° 矫正**：首扫结果可疑（行数 <3 或平均置信度 <0.6）时依次 rotate90/270 重扫，置信度总和超首扫 10% 才采纳（保守防误伤），四边形坐标映射回原图；180° 由内置 cls 模型矫正；竖排由 tall-crop 自动 rotate270 覆盖
- **7.1.11 四边形**：rapidocr 内置 quad→rec 透视矫正，15° 倾斜页 e2e 实测通过
- **e2e 验证**：正常 / 低对比度 / 15° 倾斜 / 90° / 180° / 混合横竖排 6 场景全过

### 3.2 今日实现：对照阅读（双语阅读，M7）

依据 `docs/BILINGUAL_READING_PLAN.md` v4.2 定稿方案全量落地。

- **Rust 抽取**（`translate/extract.rs`）：全部走独立 pdfium 文档句柄，绝不触碰阅读器全局 `DOC` 锁；基线聚行→段落重建、断字还原、页眉/页脚/页码噪声剔除、基于字体元数据（数学字体族 / symbolic / 上下标缩放 / 旋转）的公式识别与区域小图截取；扫描页 OCR 行→段落合并。**注意**：方案首选的 `PdfParagraph::from_objects()` 在 pdfium-render 0.9.3/0.9.4 中未被 crate 导出（`pdf` 模块私有、prelude 不含该类型），故采用方案既定的基线聚行回退路径作为主实现。
- **翻译层**（`translate/providers.rs`）：DeepL（`tag_handling=xml` + `ignore_tags` 保护公式、glossary 资源创建与语言对校验）与通用 OpenAI 兼容 / 复用 AI 两条链路；LLM 强制 `[{"i","t"}]` 严格对齐并对缺项逐段重译；429/5xx 指数退避（尊重 `Retry-After`）；占位符加随机前缀防伪造 + 回填「恰好一次且未变」校验；不可信正文沿用 `<text>` 注入防御。
- **管道**（`translate/pipeline.rs`）：缓存快路径 → 抽取（必要时 OCR）→ 保护式批量翻译 → 覆盖率与段落状态映射 → 落库；缓存键含绝对页码与目标语言 + provider，`source_hash` 保证内容变化失效。
- **译文 PDF**（`translate/pdf_writer.rs`，按需构建）：按 1..N 顺序遍历、未译页插占位页、每页「原书 p.N」锚点、每页取原书尺寸；正文用嵌入的 Noto Sans SC 写为 Identity-H CID 真实文本（可选中/可检索），公式用小图嵌入。
  - **字体分发**：`include_bytes!` 编入 Rust crate；Noto Sans SC（SIL OFL 1.1，TTF/glyf 轮廓，无 Reserved Font Name 冲突），随包附 `rust/assets/fonts/OFL.txt`。
  - **首步验证结论**：pdfium 的 `FPDF_SaveAsCopy` **不会子集化**嵌入字体（10MB 字体会给每本 PDF 增重 ~6MB，方案明确要拒绝），而 `subsetter` 会丢弃 cmap、无法供给 pdfium 的字符串文本 API。因此**按方案 §6 的回退链改用 `lopdf` 直接写 PDF**，构建期用 `subsetter` 把字体子集到全书实际用到的字形，并生成 `/ToUnicode` CMap 保证文本可抽取；导出体积与「一页一行占位」级别的极小字体子集相当（3 页测试 PDF <1MB）。
- **Flutter UI**（`lib/features/bilingual/`）：工具栏「对照阅读」按钮；右侧译文窗格（像素宽度 280–900、拖拽持久化、同开最小正文宽 360 的「后开启者优先」约束、双页上下分区、空态引导「未配置翻译服务」、整本进度与取消、逐段「本段用原文」、公式小图）。设置页新增「对照阅读」区（服务/源语言/翻译方式/后台行为/自动 OCR/并发/缓存上限/术语表/固定保留；目标语言沿用 AI 设置）。
- **编排**（Dart）：整本队列（并发可配、缓存跳过、取消、续传）与「随进度」（本页+后两页）、「手动」三模式；首次整本弹后台行为选择框，整本前弹页数/耗时/配额确认框。
- **缓存策略**：`page_translation_cache` / `translation_glossary` 新表（SCHEMA_VERSION 6→7，FK 级联）；2GB 上限 + 最久未访问优先逐出（固定保留 / 正在翻译 / 当前打开的书不可逐出，先删产物保留缓存行）；启动时与导出后静默执行；`delete_book` 显式清理 `translated/{book_id}`。

### 3.3 修复：对照阅读「翻译功能无效」（2026-09-11）

**现象**：打开对照阅读后，右栏没有任何译文；即便点「翻译本页」也无输出。

**根因**（两层，均已修复）：
1. **公式识别误判整篇正文**（`translate/extract.rs`）：`is_math_font_name` 用宽泛的 `CM` / `MT` / `TEX` 前缀匹配字体名，而 LaTeX 排版的**正文**正是 Computer Modern / TeX Gyre（如 `CMR10`、`TeXGyrePagella`），数学字体 `NewCMMath` 也命中 `MATH` 子串。于是整页 100% 字符被判为「公式」，按设计公式段落不做机器翻译、只保留小图 —— 右栏因此全空。用用户的真实论文（book 5）复现：第 2 页 32 个段落全部为 `Formula`、0 条译文。
2. **陈旧缓存不失效**（`translate/pipeline.rs`、`api.rs`、`db/repository/translate.rs`）：缓存快路径只按 (book,page,lang,provider) 命中即返回，从不校验 `source_hash` 的新鲜度。bug 1 写入的全空行会被永久命中，即使修好识别也不会重译。

**修复**：
- **收紧字体匹配**：只匹配数学**专用**字体族（`CMMI`/`CMSY`/`CMEX`/`MTMI`/`MTSY`/`LASY`/`EUFM`/`STIX`/`XITS`/`NewCMMath`/`LatinModernMath` 等），移除会误伤正文的 `CM`/`MT`/`TEX` 宽前缀。- **新增内容闸门**：`text_looks_like_formula` —— 只要文本含普通单词（连续 ≥3 个字母，含 CJK）就**绝不**判为公式；真正的公式必须有数学运算符/关系符/希腊字母。字体元数据不再单独构成判据（对应方案 §12「同字体行内数学无法本地可靠区分」的已知限制）。
- **缓存版本戳自愈**：`source_hash` 统一打上 `vN:<sha>` 提取器版本戳；缓存快路径、右栏读取、续传计数（`translated_pages`）都拒绝旧版本行，自动重译。**用户已缓存的旧行无需手动清理，打开即自愈**。

**验证**：
- 用户真实论文复测：第 2 页由 `32 formula / 0 text` 变为 `0 formula / 32 text`（第 1、3 页同样），正文恢复可翻译。
- 新增 Rust 回归单测：`math_font_name_detection`（正文/数学字体分别断言）、`content_gate_separates_prose_from_formulas`、`latex_body_in_math_font_is_not_a_formula`。
- 新增端到端测试 `rust/tests/translate_e2e.rs`：真实 pdfium 抽取 + mock LLM + 落库，并覆盖「陈旧缓存行（旧格式、全公式、无译文）必须被重译而非直接返回」。
- 另补两个 FRB 级冒烟测试（`test/translate_smoke_test.dart`、`test/selection_translate_smoke_test.dart`）：经真实 `librbwa_core.so` 验证对照阅读 `translatePage`、划词 `streamChat` 两条链路均正常返回译文。

### 3.4 对照阅读窗格改版：译文以 PDF 页面形式并排显示（2026-09-11）

用户反馈「界面太丑」，且希望**整页翻译走独立的页面通道**，直接在原 PDF 右侧显示对应的译文 PDF 页面。

**第三个 bug（仍导致「无效」观感）**：自动翻译队列把结果写入数据库后，**没有任何机制让窗格重新取数**。默认的「随进度」模式下，翻译在后台悄悄完成，而窗格仍显示「尚未翻译」——看起来就像翻译没生效。

**修复**：新增全局版本号 `translationRevisionProvider`；页面翻译完成（手动与队列两条路径）后 `++`；`translatedPageImageProvider` 监听它并重新渲染。

**改版（新的页面级通道）**：
- Rust 新增 `pdf_writer::build_page_pdf_bytes`（单页译文 PDF，内存）与 `render_translated_page`（经 pdfium 栅格化为 RGBA），并作为 `render_translated_page` FRB 接口暴露；这是与划词翻译完全独立的**页面级通道**（独立提示词管线 + 独立 PDF 组装/渲染）。
- 对照阅读窗格不再逐段罗列文本，而是**把译文渲染成与原书同尺寸的 PDF 页面**，紧邻原文显示（单页 1 张、双页 2 张，各带「译文 p.N」锚点）；未译页显示占位卡片 + 「翻译本页」；顶部保留目标语言、整本翻译、导出 PDF、关闭。
- 批量导出（`translated/{book_id}/{lang}.pdf`）复用同一套单页组装逻辑，两者产出一致。

**验证**：新增/更新 `test/bilingual_test.dart`（页面图像 provider、revision 失效重渲染、窗格渲染出 `译文 p.N` 与页面位图、无溢出）；`test/translate_smoke_test.dart` 增加页面渲染通道断言（真实 `librbwa_core.so`）；用真实论文探针确认单页渲染输出 595×841 位图。

### 3.5 修复：整页翻译「API 完全没有被调用」（pdfium 并发竞态，2026-09-11）

**现象**：用户反馈翻译完全无效，抓包/日志显示**翻译 API 一次都没被请求**。

**根因（第三个、也是最关键的一个）**：**pdfium 不是线程安全的**。`pdfium-render` 的 `thread_safe` feature 只让包装类型 `Send + Sync`，C 库本身仍有全局状态。而翻译侧的段落抽取/页面渲染跑在后台 worker 上、并发数默认为 3，与阅读器自身的渲染并发调用 pdfium 时，**文本抽取会静默返回 0 个段落**、渲染报 `PdfiumLibraryInternalError`。于是每页都走「空页」分支、直接写空缓存，**根本不会发起翻译请求**；并发首绑定时 `Pdfium::new()` 的 `assert!(BINDINGS.get().is_none())` 还会让进程 SIGTRAP 崩溃。

**复现**：用真实 `librbwa_core.so` + 用户数据库副本 + 本地 mock 服务驱动应用真实的 `onVisiblePages` 队列入口 —— 修复前请求数 **0**、队列报 `PdfiumLibraryInternalError`；并发探针 3 线程抽取返回 **0/0/0** 段落（串行时是 32/11/11）。

**修复**（`rust/src/pdf/pdfium.rs`、`translate/*`）：
- 新增进程级 `PDFIUM_LOCK`，**所有** pdfium 入口（阅读器渲染、缩略图、文本抽取、翻译抽取/渲染、导出）统一串行化；`with_doc` / `open` / `close` / `render_thumbnail_file` / `extract_document_text` 全部纳入。
- 新增 `with_document_file`（独立句柄 + 锁）与 `with_pdfium_lock`，翻译侧改走它们，不再裸调 `shared_handle()`。
- 库绑定改为 `PDFIUM_INIT` 双检锁初始化，消除并发首次绑定的断言崩溃。
- **防御**：文本版 PDF 抽取到 0 段落不再当成「空页」缓存（会被永久跳过），而是报错让调用方重试。

**验证**：
- 并发探针修复后：3 线程抽取 `32/11/11` 段落、3 页并发渲染全部 `595×841`。
- 真实 FRB 流程复测：`onVisiblePages` 发出 **12 次** API 请求、3 页翻译完成、无错误（修复前 0 次）。
- 新增常驻回归单测 `pdf::pdfium::tests::concurrent_text_extraction_is_correct`（并发抽取须返回正确文本）；全量 Rust 测试连跑 3 次稳定通过。

### 3.6 修复：随进度自动翻译「没有触发入口」（配置异步竞态，2026-09-11）

**现象**：用户仍反馈「根本没有到调用 API 的入口」。用**真实阅读页 + 真实核心 + 用户数据库副本**复现：工具栏「对照阅读」按钮**存在且可打开窗格**、手动「翻译本页」**能发出请求**，但**打开书籍时随进度自动翻译发出 0 个请求** —— 与用户描述一致。

**根因（Dart 侧竞态）**：`TranslationQueueNotifier.onVisiblePages` / `resumeIfNeeded` 用 `ref.read(translationConfigProvider).valueOrNull` **同步**读配置；而 `TranslationConfigNotifier` 是 `AsyncNotifier`，配置在应用启动时**异步**从 Rust 加载。阅读页在打开书籍的瞬间就调用 `onVisiblePages`，此时配置通常尚未加载完 → `tc == null` → **直接 return，且之后不再重试**。因此「随进度」模式全程静默不翻译。（手动「翻译本页」不读该配置，所以能工作——正是用户观察到的差异。）

**修复**（`lib/features/bilingual/providers/translation_queue_provider.dart`）：改为 `await ref.read(translationConfigProvider.future)`，等待配置就绪后再判断模式，消除竞态。同时修复窗格：配置加载中不再误显「未配置翻译服务」，改显加载指示（`translated_pane.dart`）。

**验证**：
- 聚焦探针（真实核心 + mock 服务，**在配置加载前调用**）：修复前请求数 0、修复后 **12 次**、3 页完成无错误。
- 新增回归测试 `onVisiblePages awaits an unloaded config instead of bailing out`；已确认它在旧代码下**失败**（能捕获该 bug），修复后通过。
- 另用真实 `ReaderPage` 探针确认工具栏「对照阅读」入口存在、按钮→窗格→「翻译本页」链路可用。

**关于"装上仍是旧版"**：`dist/` 内安装包（08-10 打包）早于对照阅读功能，二进制中**不含**任何翻译 UI 字符串；请用最新构建（`flutter build linux --release` 后运行 `build/linux/x64/release/bundle/ZhiYue`），或重新执行 `scripts/build_packages.sh` 生成新安装包。

### 3.7 修复：`translation_overview` 自死锁 + 中英互译缓存键错位（"API 依然没被调用"的真正原因，2026-09-11）

**现象**：用户以 `flutter run -d linux` 运行**开发中版本**，仍反馈「译文没有显示在对应位置，且 API 没有被调用」。（此前怀疑的"运行了旧 AppImage"不成立——用户跑的是 debug 版。）

**排查**：用真实书籍 + 用户数据库**副本** + 本地 mock LLM（全程未用用户真实 Key）逐层实测，链路本身（抽取 / 提供方 / 渲染）均正常，但在**用户真实配置**下暴露两个都会导致"完全无反应且无报错"的 bug。

**根因 1（致命，自死锁）**：`crate::translate::translation_overview` 先 `let conn = db::db()` 取到**进程级非可重入** DB 互斥锁，随后又调用 `cache_key()` —— 而它内部再次 `db::db()`，于是**同一线程二次加锁、永久卡死**。阅读页每打开一本书都会经 `resumeIfNeeded` 调用 overview，锁一旦被自己占死就再也不释放，之后**所有**翻译/DB 调用都阻塞 —— 表现正是"没有入口、不调 API、无任何报错"。

**根因 2（中英互译键错位）**：缓存行的 `target_lang` 列被写成了**每页生效语言**（中英互译 → 中文/英文），而读取用**配置键**（中英互译），列与键不一致，于是已翻译的页永远查不到。用户的真实设置恰好是 `中英互译`。

**修复**：
- `rust/src/translate/mod.rs`：新增 `load_translation_config_with` / `load_ai_config_with` / `cache_key_with`（复用已持有的连接）；`translation_overview`、`page_has_translation` 改用 `*_with`，不再二次加锁。
- `rust/src/db/repository/translate.rs`：`save_page_translation` 新增 `key_lang` 参数，`target_lang` 列写**配置键**；每页生效语言保留在 JSON 载荷中（渲染/导出仍按其显示）。
- `rust/src/translate/pipeline.rs`：把 `key_lang` 传入内部函数并用于两处写入。

**验证**（真实书籍 5 + 真实 PDF + DB 副本 + mock LLM）：
- 修复后 `translation_overview(5)` **5 秒内返回**（修复前用等价的"持有 guard 再调 cache_key"探针复现：3 秒超时 panic）。
- 控制台：`OVERVIEW total=88 translated=0 lang=中英互译` → 翻译第 4 页发出 **3 次** HTTP → `page_has_translation=true` → `OVERVIEW2 translated=1` → 渲染 595×841。修复前 `READBACK: MISS`。
- 新增常驻回归：Rust `rust/tests/translate_overview_regression.rs`（死锁 + 键往返）、仓库单测 `configured_key_is_stored_while_effective_lang_stays_in_payload`、FRB 冒烟 `test/bilingual_overview_smoke_test.dart`（真实核心 + 中英互译）。
- 全量：Rust **121** 单测 + 2 集成 + 回归全绿；Flutter **202** 测试全绿；`flutter analyze` 无问题。

**产物更新**：已重建 `rust/target/release`（`flutter test` 用）、`build/linux/x64/debug/rust_target` 与 debug bundle（`flutter run -d linux` 用）、`build/linux/x64/release/bundle`、`dist/ZhiYue-x86_64.AppImage`，并重新覆盖 `/Data/Appimage/ZhiYue.AppImage`（旧版备份 `ZhiYue.AppImage.bak-20260911`）。

**注意**：若此前已运行过卡死的旧进程，需**完全退出后重启**；`dist/` 里的 Windows 安装包（09-10）仍是旧版，如需 Windows 端请重跑 `scripts/build_packages.sh`。

### 3.8 代码梳理：队列两处行为修复 + 冗余清除（2026-09-14）

**行为修复（随进度模式，均为静默缺陷）**：
1. **首批之后不再自动翻译**：`onVisiblePages` 的首批耗尽后 `_drain` 把 `running` 置回 false，但 `bookId` 保留，下一页翻页时"重新武装"分支（`bookId == null` 才触发）不再命中，工作循环在 `!running` 上立即退出——**只有第一批判页会翻译**。现改为每次批量都显式 `running = true` 再驱动。
2. **失败页计入进度并无限重试**：页翻译出错时 `donePages` 照样 +1（进度虚高），且未缓存页每翻一次页重试一次（配置错误时热循环打满）。现失败页不计入进度、进入 `_failed` 集合不再自动重试（「翻译本页」仍可手动重试）。

**逻辑简化**：
- 队列播种从"overview + 逐页探测"（每页 2 次 KV 解析的 N+1）改为新增 API `get_translated_pages` 一次批量读取；`onVisiblePages` 同样一次读取代替每目标页探测。
- 移除名存实亡的 `pause()`/`resume()`/`paused` 状态：切书的 `pause_resume` 行为由 `cancel` + 回书时 `resumeIfNeeded`（缓存页自动跳过）达成，旧的 paused 标志自己永远不会恢复。
- 译文 PDF 导出进度改为**真流式**（原实现把事件缓冲到构建结束才一次性发出）；导出与单页渲染现在同样**拒绝过期抽取器缓存行**（原导出会混入 v1 旧行）。

**清除的冗余**：
- Dart：`bilingual_utils.dart` 整文件（`substituteFormulaTokens`/`paragraphStatusStyle` 均无调用方——窗格已改为 PDF 页渲染）、`PageTranslationNotifier.refresh()`、窗格头部多余的 Column 包裹。
- Rust：`pdf_writer::translated_pdf_exists`（无调用方）、`restore_placeholders` 中的自替换空操作、`FontMetrics` 收集字符时与 `page_used_chars` 的重复块、clippy 提示（`Iterator::last`→`next_back`、连写 `replace` 合并、区间判断、`&PathBuf`→`&Path` 等 6 处），lib 警告 11 → 6（余者为 FRB 签名与 openai 存量风格提示，不在本次范围）。

**验证**：Rust 121 单测 + 2 集成全绿；Flutter **203** 测试全绿（含新增回归：`a finished batch re-arms…`、`a failed page is not counted done…`）；`flutter analyze` / `cargo clippy` 无新增。产物已重建（debug 核心、release bundle、`dist/` AppImage）；`/Data/Appimage/ZhiYue.AppImage` 因应用正在运行未覆盖，关闭应用后可用 `dist/ZhiYue-x86_64.AppImage` 更新。

### 3.9 体验升级：左右对照分栏 + 译文版式保留（2026-09-14）

**背景**：功能可用后用户反馈两点：① 对照阅读不该是右侧独立窗格，应当"像双页显示那样左原文右译文"；② 译文页是单栏重排，丢了原文版式，显得凌乱。

**对照分栏（Flutter）**：
- `translateOpen` 时阅读区本身 50/50 分栏（左原文 / 右 `TranslatedColumn`，细分割线，无拖拽把手），原右挂载窗格与 `translatedPaneWidth`/resize/clamp/KV 全套删除。
- 开启对照时若处于双滚/双翻，自动切为单页并记住原模式（`TranslationPaneState.modeBefore`），关闭时恢复——左右始终"原文一页 ↔ 译文一页"。
- 译文栏复用原页面卡片（`translatedPageImageProvider` 渲染），翻页即跟随；dpiScale 1.0→1.5。

**版式保留（Rust `pdf_writer` overlay）**：
- 页面合成改为：**原页光栅（JPEG q88，24MP 上限）作整页背景 → 文本段落行矩形（`TranslatedParagraph` 新增持久化 `rects`）涂白 → 译文按段落原位绘制**（宽度=矩形宽，字号按行高中位数估算 6–28pt，超高 ×0.9 收缩至 5.5pt；Identity-H 矢量文本，可选中/可检索）。
- 图表、公式段、页眉页脚、页码、分栏结构全部由背景原样保留（公式段不涂白）；分栏论文的左右栏自然各归其位。
- 单栏重排降级为回退路径（占位页 / 旧缓存行 / 背景渲染失败时仍可用）；导出 PDF 与对照视图同版式（未译页保持矢量占位，控制体积）。
- 兼容性：`EXTRACTOR_VERSION` 2→3（旧行无 rects，自动判过期重译）；公式小图截取管线移除（overlay 直接保留原页像素，`translated/{id}/formulas/` 不再产生）；FRB codegen 更新模型。

**验证**：
- Rust 123 单测 + 2 集成全绿（新增 overlay/whiten/fit 测试）；`flutter analyze` 0 问题；Flutter 203 测试全绿（新增"翻页跟随"回归）。
- 真实书籍 5 实测（DB 副本 + mock LLM）：正文页/目录页 overlay 渲染正确——译文按段落原位排版、段落间距与原页一致、图表与页码由背景保留（渲染位图人工核对通过）。
- 产物：debug 核心、release bundle、`dist/` 与 `/Data/Appimage/ZhiYue.AppImage` 均已重建部署（当时应用未运行）。

### 3.10 修复：显示公式/图表在译文页被涂白（2026-09-14）

**现象**：用户反馈公式和图片"没有完全按照原本显示"。真实书复现：第 7 页的三个编号公式、第 10 页的公式组与交换图全部被涂白后重绘成平文本。

**根因（两个叠加）**：
1. **公式判定过窄**：整段公式需"≥80% 数学信号 + 无普通词"才保留，而 `Γ ⊢ t : T_effect` 的下标词 "effect"、cases 环境的条件词（"activating if σ ⊬ d"）都让它被判成散文 → 涂白 + 平文本重绘。
2. **显示公式被并进正文段**：公式行与前后正文行的垂直间隙不足以触发分段阈值，公式行被合并进段落 → 即使公式判定命中也整段涂白。

**修复（`extract.rs`，EXTRACTOR_VERSION 3→4）**：
- `fallback_paragraphs` 行级拆分：窄且水平居中的行（显示公式特征）自成段落，与全宽正文在交接处断开；连续居中行按中心聚成同一公式块。
- `is_whole_paragraph_formula` 三信号判定（任一命中即保留原像素）：① 经典规则（≥80% 数学信号 + 无普通词）；② **数学字母占比** ≥60%（字母字符中数学字体/上下标缩放的比例）且全文长词 ≤1——命中带下标词的公式；③ **居中短块**（行宽 ≤ 页面 P95 行宽 ×0.7，中心贴近 0.25/0.5/0.75，行尾带 `(N)` 编号时容差放宽到 0.16）且数学信号 ≥12%——命中 cases 环境与多行推导。
- 保留原像素的公式段不翻译、不涂白；正文段落照常翻译（内联公式以占位符原文本回填）。

**验证**：新增 3 个分类单测（下标词公式 / cases 环境块 / 左对齐短标题不误判），`latex_body_in_math_font_is_not_a_formula` 回归保持通过；Rust 126 单测 + 2 集成全绿，Flutter 203 全绿。真实书复检：第 7 页公式 (1)(2)(3)、第 10 页公式 (5)(6)(7) + 交换图 + 多行证明全部原样保留在原位，正文各自原位翻译（渲染位图人工核对）。图片（矢量图形/光栅图）位于整页背景中，涂白只作用于文字行矩形，不受影响。产物已全部重建部署。

### 3.11 反馈修复：行内公式保真 + 检测覆盖 + 真双页样式（2026-09-14）

**反馈**：① 行内公式一部分被涂掉；② 常见公式字体/符号识别不全；③ 对照视图仍像一个右侧边栏，而不是双页阅读。

**修复**：
1. **内联公式段落整段保留原像素**（`pipeline.rs` 不再送翻 / `pdf_writer.rs` 不涂白不重绘）：行矩形是文字紧边界，分数/求和号等高出行的公式会被涂白切断——原像素保留是唯一忠实的做法；这些段落的原文本在左栏本来可见。
2. **检测覆盖**（`extract.rs`，EXTRACTOR_VERSION 4→5）：字体表加入"名字含 MATH 的族"通配（STIXTwoMath / TeXGyreTermesMath / LibertinusMath / DejaVuMath / EuclidMath 等）与 TX/PX/WASY 系列；符号表加入 ′ ″ ⊢ ⊣ ⊨ ↦ ≡ ≃ ≍ ∥ ⌊⌋ ⌈⌉ ∠ ¬ ∵ ∴ ⊃ ⊇ ∋ ↑↓⇑⇓↕ 等常用数学符号。
3. **真双页样式**（`translated_pane.dart` 重写 + 工具栏收纳操作）：右列去掉自有色底/标题栏/分割线，与阅读区同背景；译文页按**与原文页相同的显示尺寸**（物理页高 × 缩放）绘制，同一 16px 阔距的节奏；列表随翻页跳到对应页（同 stride 模型），观感即"左页原文 / 右页译文"。导出 PDF / 整本翻译按钮移入工具栏（仅对照开启时显示）；整本进度以浮动胶囊显示在右页底部。

**验证**：Rust 126 单测 + 2 集成全绿（字体/符号测试扩充）；`flutter analyze` 0 问题；Flutter 203 全绿（跟随断言改为视口位置判定，因为 itemExtent 列表的 cacheExtent 会保留相邻页芯片）。debug 核心/release bundle/AppImage 已重建；`/Data/Appimage` 因应用运行中未覆盖（新版在 `dist/`）。

### 3.12 修复：译文符号消失（字体缺希腊字形）+ 清晰度 + 内联公式恢复翻译（2026-09-14）

**用户截图反馈**：① 上下文符号（Γ、γ、φ）在译文中消失/被涂白；② 公式后跟随的文字没有被翻译；③ 译文与公式/图片模糊。

**根因与修复**：
1. **符号消失的主因是字体**：内置 Noto Sans SC 子集**完全没有希腊字母字形**（Γ γ φ σ Σ κ μ η 全缺），翻译回填的这些字符画成空白（.notdef）。换用**完整版 Noto Sans SC 可变字体**（31k 字形，OFL，17.8MB，运行时子集化体积不受影响）——希腊/西里尔全量覆盖；仍缺的 ⊢/↦ 等通过 `FALLBACK_GLYPHS` 映射到存在的形近字符（|、→、=），不再静默丢失。新增常驻字形覆盖测试。
2. **公式后文字不翻译**：上一版"内联公式段落保留原像素不翻译"过于激进（数学论文里大量正文段含内联符号）。按用户要求恢复：这些段落**重新送翻**，译文在原位绘制（内联公式占位符以原文本回填）；涂白纵向 padding 0.0025→0.004 减少高出的数学字形被切。
3. **模糊**：对照视图渲染 dpi 1.5→**3.0**（背景光栅与最终合成同比例，1:1 像素无重采样），JPEG 质量 88→90。实测 A4 页 1785×2525、渲染 ~210ms。
4. EXTRACTOR_VERSION 5→6（管线翻译范围变化，旧行自动重译）。

**已知限制**（本轮不解决）：该 PDF 的数学字体**没有 ToUnicode 映射**，抽取层拿不到 γ/φ 等字形文本（源文本里就是 "(, )"）——译文对应位置无法回填这些符号；左栏原文完整可见。后续可探索按字形反查编码。

**测试装置注意事项**：本机存在**透明流量拦截**——发往 `127.0.0.1` 任意端口的 HTTP 请求会被转发到真实 LLM（探针的本地 mock 从未收到连接，但翻译确实发生）。今后探针须以文件级 trace 验证 mock 是否被命中，否则可能误用用户真实 API 额度。

**验证**：Rust 127 单测 + 2 集成全绿；`flutter analyze` 0 问题；Flutter 203 全绿；真实书页 10 渲染位图人工核对（Γ/γ/φ 正常显示、公式与交换图保留、dpi 3 文字清晰）。

### 3.13 修复：剩余符号缺失（65 字形回退）+ 符号丢失段落保真（2026-09-14）

**用户反馈**（第 11 页对照）：译文中仍有方框（∘ 复合符等）；符号丢失的段落被涂白重绘成破碎文本（"对于每个 (, ) ∈ Γ"、"() = 0 称为健全性…"），LLM 还被破碎源文本带偏产生错译。

**修复**：
1. **字形回退全量化**：对内置字体做 65 项符号清点（∘ ∙ ⋆ ∖ ⋮⋰⋱ ⊔⊓⊎⊟⊞⊠⊛ ≂≊≍≎ ≺≻≼≽≾≿ ⊭⊮≉≹ ℕℤℚℝℂℙ𝔽 ⟶⟵⟸⟹⟺ ↠↪↩⇉ ⌢⌣ ∎ ϑϕϖϱϵϰ ₀₁₂ₙ¹²³ⁿ ∤），全部加入 `FALLBACK_GLYPHS` 映射到存在的形近字符（∘→○、ℝ→R、₁→1、≻→>、ϑ→θ 等）；解析支持**递归回退链**（目标字形也可能缺失）。常驻测试断言整份清点表无 .notdef。
2. **符号丢失段落保真**：新增 `text_has_symbol_gaps` —— 括号组内无任何字母（"(, )"、"()"）或字母+多空槽（"track(1, 1)" 即原 track(f₁,g₁) 的抽取残迹）即判定为不可恢复数学段：**不送翻、不涂白、不重绘**，保留原像素（公式编号引用 "(10)" 单槽仍正常翻译）。管线与写入器同步生效，**对既有缓存立即起效（无需重译）**。
3. **占位页字形修复**：`page_used_chars` 补入空格/全角冒号/破折号（占位页锚点的空格此前画成方框）。

**验证**：真实书页 11 用用户自身缓存渲染（**零 API 调用**，行戳强制当前）——公式 (9)(10)(11)、交换图、证明推导全部原样保留；符号丢失段（定理 7 块、"A sequence of pairs…" 段）保留英文原文而非破碎重绘；译文段 Γ 正常显示。Rust 128 单测 + 2 集成全绿；Flutter 203 全绿；clippy 维持基线。产物全部重建部署。

**排障注记**：诊断过程中曾用 `pkill -f` 杀探针导致 shell 自杀（命令行含同串），已改用 PID 精确终止；探针自身的诊断块曾复现 DB 自锁模式（持有 guard 调用重入函数），与 3.7 节产品级修复同源。

### 3.14 反馈修复：不再整段保留原文，仅保留公式（2026-09-14）

**用户反馈**：3.13 的"符号丢失段落保真"矫枉过正——整段保留原文（英文）导致公式周围的正文也不翻译。要求：**不要整段保留原文，仅保留公式，后续文本正常翻译**。

**修复**：
1. **撤销整段保留**：删除 `text_has_symbol_gaps` 及其三处调用（`pipeline.rs` 段落过滤、`pdf_writer.rs` 涂白与绘制跳过）。含不可恢复数学符号的段落重新**正常送翻、涂白、重绘译文**，只有整体判定为公式的段落（`ParagraphKind::Formula`）保留原像素。
2. **公式分类补强（规则 4）**：撤销兜底后暴露出显示公式的分类缺口——`recoverΓ(trackΓ(, )(, )) = recoverΓ(, ) (10)` 这类**算子名公式**（字母串是数学字体的 recover/track，规则 1 的"遇到真词即否决"、规则 2 的"≤1 长词"、规则 3 的"居中短块"都不命中）会被误当正文涂白重绘。新增规则 4：`math_ratio ≥ 0.9`（含字母在内全部数学字体）+ 长词串 ≤ 6 + 符号占比 ≥ 0.3（公式 ≈0.5，连字符正文 ≈0.1）+ 至少一个强数学字符。守护测试覆盖"数学字体正文/连字符正文不得误判"。
3. **裁剪行补省略号**：`write_overlay_page` 在最小字号仍装不下译文时按 footprint 截断，此前静默丢弃溢出行（涂白却无内容）。现于被截断处补 '…'，并把 '…' 加入 `page_used_chars` 字形清点。
4. **EXTRACTOR_VERSION 6→7**：v6 缓存行中符号丢失段落的译文为空串，若不升版会涂白后回退原文（正是本次要消除的现象）；升版强制重译。

**验证**：Rust 131 单测 + 3 集成全绿（新增规则 4 正/反例、overlay 省略号回归、e2e 断言符号丢失段必须送翻）；clippy 维持基线 6 警告；`flutter analyze` 0 问题；Flutter 203 测试两遍全绿。**视觉验收**（真实书页 11，DB 副本 + 本地 mock LLM 全链路，零真实 API）：脚本提取译文页矢量文本 + 逐条带灰度均方差双 ground truth——顶部公式 5.5、式 (9) 2.5、交换图 2.0、式 (10) 4.1、证明块 3.2、式 (11) 6.4（均为 JPEG 噪声级，原像素保留）；正文带 14~24（正常重绘）。多阈值墨量复核确认占位中文清晰可见（小号抗锯齿笔画多为 100~200 灰度）。产物全部重建部署（debug 核心 / release bundle / `dist/` 与 `/Data/Appimage/ZhiYue.AppImage`，应用未运行）。

**排障注记**：首次视觉验收判官（纯像素统计、无图像输入）将公式区域误判为"被涂白重绘"，与缓存数据矛盾；以提取文本 + 条带差值定论。mock LLM 起初只应答 i=0——请求体的 segments 是**转义后的 JSON 字符串**（字节为 `\"i\":`），按裸串计数恒为 0，改为解析 JSON 后按实际索引应答。

### 3.15 代码梳理（第三轮）：死代码清除 + 重复逻辑合并 + clippy 清零（2026-09-14）

**背景**：3.13/3.14 两轮反转后积累的残余（公式截图管线、写死不读的字段），加上长期存在的重复实现与 clippy 基线警告。三个探索代理全库交叉核对后按 9 个阶段执行，**全部为行为保持的删除/合并**。

**Rust**：
1. **死代码删除（~90 行）**：`FormulaRegion.image_path` 生产端恒 `None`（截图管线已废），随之删除 `para_image_height`（恒返 0）、`emit_formula`（恒返 false）、`write_flow_page` 中永不可达的公式图片分支（公式段经 `display_text` 回退原文，行为等价）；同步修正 8 处"公式小图"陈旧注释与 `FormulaRegion` 字段文档（字段保留为缓存兼容，标 VESTIGE）。
2. **重复逻辑合并**：`build_translated_pdf` 内联缓存读取 → `load_cached_translation_with`（沿用 `*_with` 模式保住键外提的性能）；`dir_size` 双实现合一（db 侧 `pub(crate)`）；extract.rs 提取 `p95_width` / `is_centered_short` 共享（原三处各写一份）；`attach_formulas` 双分支逐字重复的 regions 赋值合一（`Text` 守卫恒真）；删 `extract_page` 冗余 `_pg` 取得、`union_and_max_line` 不可达空分支；`get_translated_pdf_path` 改调 `translated_pdf_path`（原重复实现 `sanitize_lang`）；write_overlay_page 消除 f32/f64 `pw,ph` 遮蔽（改 `page_w/page_h`）。
3. **clippy 6 → 0**：`stream_chat/stream_vision` 的 `manual_async_fn` 加 allow（RPITIT `+ Send` 是 FRB 执行器必需，trait 文档已注明）；4 处 `too_many_arguments` 加 allow（api.rs 两处为 FFI 签名，db 两处与既有 `update` 的 allow 对齐）。
4. **Cargo.toml 瘦身**：删未用的 `tokio "fs"`、`rusqlite "blob"`、`pdfium-render "paragraph"` feature 与注释掉的 async-openai 残行（依赖本身全部在用，逐一核对）。
5. **测试去重**：`src/test_http.rs`（`#[cfg(all(test, feature="ai"))]`）共享 loopback mock server（JSON 与 SSE 两种变体）与 `read_request`，openai.rs / providers.rs 两套重复实现合一；`tests/common/mod.rs` 共享 scratch-dir 与 settings upsert；删 overview 回归里的死绑定与 e2e 的调试 eprintln 脚手架。

**Dart**：
1. **死代码删除**：`TranslationQueueState.estimatedRemaining/currentPage`（零引用/只写不读）、`PageTranslationState.progressDone/progressTotal`（只写不读）、`TranslationRepository.extractPageParagraphs/clearTranslations/clearTranslationArtifacts`（零调用方，fake 配套字段一并删）、`TranslationPaneState.copyWith`、`MarkToolNotifier.toggleTool`（生产只用 `setTool`，测试同步调整）、两个从未 requestFocus 的 FocusNode、`PanelResizeHandle.cursor` 参数、scan_overlay 冗余 case 标注；pubspec 删 `path` 与 `cupertino_icons`（全库零 import）。
2. **逻辑优化**：`aiActionLabel` 共享（原 result_card / message_bubble 各一份 switch）；`_rightOrder` 单元素列表机制删除（`_aiPanelSub` 唯一职责即维护它，一并删除，钳制逻辑直接化）；LRU 触碰+驱逐三份拷贝 → `lib/core/lru.dart` 的 `lruTouch`；目标语言默认值三处 → `translateTargetLangProvider` 派生。
3. **测试去重**：`test/helpers/fake_settings.dart`（取最全的 map 版实现）替换 5 个私有 `_FakeSettings`；integration_test 的机器相关用例加"本机调试专用"文档头。

**文档对齐**：bilingual_workflow.html 修正 3.14 反转后自相矛盾的"整段保留原文/公式小图/v6 版本戳/测试基线"描述；IMPLEMENTATION_STATUS 里程碑表与"当前技术状态"计数更新；FEATURES 7.4.2 公式"原页小图"→"原页背景像素"；ARCHITECTURE 模块表补 translate/export、删不存在的 `PdfService`/`SearchIndex` trait、async-openai → 手写 SSE、仓储约束改为与现状一致；TECH_ROADMAP / BILINGUAL_READING_PLAN 加"历史文档"头部注记；README M0–M6 → M0–M7；.gitignore 删未用的 `/assets/models/`；setup.sh 去掉一次性会话措辞。

**验证**：Rust 130 单测 + 2 集成全绿；**clippy 全 target 0 警告**（此前基线 6）；全 feature 构建通过；`flutter analyze` 0 问题；Flutter 202 测试全绿（-1 为删除的 toggleTool 测试，其行为已由 setTool 用例覆盖）。产物重建部署（debug 核心 / release bundle / `dist/` 与 `/Data/Appimage/ZhiYue.AppImage`）。

### 3.16 重构：移除自研翻译管线 + 设置内可选下载 BabelDOC 引擎（2026-09-18）

**决策**：自研逐页翻译管线（抽取→provider→覆盖式写入器 + 页级缓存）在十余轮修复后已触及启发式天花板（涂白重绘使每个抽取错误都可见、公式分类四规则军备竞赛、无 ToUnicode 符号空洞等结构性缺陷）。改由 **BabelDOC**（经 `pdf2zh-next`）承担翻译，用户可在设置中自行选择是否下载该引擎（约 1.5GB，不随包分发）。

**① 删除管线**（回滚点 tag `pre-babeldoc-replacement`，commit 46c625c / 26c77c6）：
- Rust 删除 `translate/{extract,pipeline,providers,pdf_writer}.rs` 约 4.5k 行（含测试）与两个集成测试；`mod.rs` 仅保留引擎无关簿记（在飞注册表、`translated/` 目录、配置 KV、产物 LRU）；`api.rs` 移除 10 个管线 FFI
- 页级模型（Paragraph/PageTranslation/FormulaRegion 等）删除；**schema v7→v8 迁移 DROP `page_translation_cache`**（术语表保留）；LRU 驱逐候选改按产物目录 mtime 排序
- Cargo 移除 lopdf/subsetter/ttf-parser 与内嵌 NotoSansSC 字体（17MB）——**librbwa_core.so 从 ~55MB 降至 ~36MB**
- Dart 删除队列/位图 provider、bilingual_actions 与相关测试；对照窗格改为引擎引导占位；工具栏保留「对照阅读」开关；`flutter analyze` 0、测试 190 绿

**② 引擎下载器**（commit 9815651 / ff8cbdd）：
- Rust `translate/engine.rs`：五步幂等安装（uv → `uv venv --python 3.12` → `uv pip install pdf2zh-next==2.9.0` → `babeldoc --warmup` → `engine.json` 清单），状态机 + 流式事件 + 取消（轮询杀子进程）+ 失败终事件；卸载保护：安装中/翻译中拒卸，**仅删除由我们创建的资产缓存**（既有 `~/.cache/babeldoc` 保留）
- 设置卡片「翻译引擎」：开关 + 体积/许可披露 + 确认框 + 进度/取消 + 失败重试 + 卸载；`EngineController` 驱动
- **真实安装冒烟**（本机，镜像配置）：**热装 18s / 冷装 103s，实占约 1.5GB**（venv 1.2GB + 资产 337MB）；跑通 `--skip-translation` 排版管线（零 API）：用户书库论文 mono/dual PDF 产出，**页数严格 1:1**、矢量文本可提取、dual 同页左右并排
- 冒烟暴露并修复四个真实缺陷（均有回归测试）：GitHub release 资产源在本机被完全阻断（改用 PyPI simple 索引，uv wheel 内含二进制）；镜像相对链接 `../../packages/...` 未消解且选中了最旧的 0.0.5；无 User-Agent 被清华镜像 403；`uv venv` 以尚不存在的目录为 cwd 导致 ENOENT
- 足迹治理：uv 以 `--no-cache` 运行且 `UV_PYTHON_INSTALL_DIR`/`UV_CACHE_DIR` 内收进引擎目录（首测曾在用户 `~/.cache/uv` 留下 9.7GB）；步骤失败附可操作的镜像提示（已验证南大 python-build-standalone 镜像与清华 PyPI 镜像）
- 许可：新增 [`docs/THIRD_PARTY.md`](THIRD_PARTY.md)，登记 BabelDOC（AGPL-3.0，独立进程集成，不链接）

**当前状态**：对照阅读显示引擎引导占位（未安装）或等待接入（已安装）；侧车任务/分块渲染/译文回填是下一阶段。

### 3.17 内置引擎测试版 + 整本翻译通路打通（2026-09-18）

**目标**：出可实测的测试版——引擎随包分发（免 1.5GB 下载），并打通"点一下翻译整本"的最小通路。

**内置引擎（bundle 内 `babeldoc/`）**：
- 运行时解析：`<exe_dir>/babeldoc/engine.json` 存在即视为**已内置**（与 OCR 模型的 `exe_dir/models` 同惯例）；`EngineStatus.bundled` 上报，设置卡片显示"已内置"并禁用卸载；`engine_dir()` 优先级 = 测试覆盖 > 内置 > `RBWA_BABELDOC_DIR` > 应用数据目录
- 布局与运行方式（关键设计，规避 AppImage 挂载点漂移）：`python/`（uv 独立 CPython，可重定位）+ `site-packages/` + `bin/uv` + `engine.json`；运行用 `python -c "…cli()"` + `PYTHONPATH` 直连 site-packages，**不依赖 venv**（venv 的 shebang/软链是绝对路径，AppImage 每次挂载路径不同必坏）
- 资产：`--generate-offline-assets` 生成的离线包随包内置时首用自动 `--restore-offline-assets`；本机构建以 `RBWA_SKIP_ASSETS_ZIP=1` 跳过（缓存已有 337MB 资产），无网机器可去掉该开关出可携带版
- 打包：新增 `scripts/build_bundled_test.sh`（在 bundle 内以 uv **离线**从热缓存重建 venv 取 site-packages、含引擎自检 `--version` 门禁），产出 `dist/ZhiYue-1.0.0-with-engine-x86_64.AppImage`（**380MB**，引擎压缩后；含引擎的 bundle 1.2GB）

**整本翻译通路（v1，替换被删管线的最小可用版）**：
- Rust `translate/job.rs`：单任务 runner（复用 AI 设置的 OpenAI 兼容配置；语言码映射；`--watermark-output-mode no_watermark`；行级进度→粗阶段（解析版式/翻译中/排版输出）；取消杀进程；产物扫描（水印模式会改文件名）+ `translated/{book_id}/manifest.json`）；失败经终事件上报（哨兵模式）
- `pdf::render_page_file` 新增（任意 PDF 文件的第 N 页光栅化）；FFI：`translate_book`(流) / `cancel_book_translation` / `get_book_translation` / `clear_book_translation` / `render_translated_page`
- Dart：`bookTranslationProvider`（family）+ 译文页图像 provider（dpi 3.0）；**对照窗格三态**：未装引擎→下载引导；引擎就绪→「开始翻译」+ 进度 + 取消；有产物→按页渲染 mono PDF（与原文同尺寸、翻页跟随、p. 标签、重新翻译/删除译本菜单）

**验证**（全零真实 API）：
- mock LLM 对**内置引擎**（bundle 目录、python+PYTHONPATH 方式）跑真实论文 pages 10-12：产出 mono+dual，**页数 88=88=88（严格 1:1）**，dual 同页并排（1191=2×595），译文含 mock 标记（通路真的走通）
- **意外收获**：第 11 页——当初自研管线产出 `(, )` 符号空洞、逼出十余轮修复的那一页——BabelDOC 解析出的文本**数学符号完整**（`(trackΓ(𝑓1, 𝑔1) ∘trackΓ(𝑓2, 𝑔2))(𝛾, 𝜑) = …`），即该结构性缺陷在引擎侧不复现
- Rust 89 测试 + clippy 0；`flutter analyze` 0；Flutter 192 测试全绿（窗格三态 3 个新测试）

**已知边界**：整本粒度（无分块/随进度）；进度为粗阶段（引擎的 rich 进度条非 TTY 下不可解析）；`--pages` 分块与 dual 导出 UI 待接入；引擎内置版首次翻译若缺资产会自动联网补齐。


### 3.18 引擎整体替换：内置 RetainPDF 管线（2026-10-07，分支 feat/retain-engine）

**决策**：BabelDOC（AGPL-3.0，按需下载 ~1.5GB）整体替换为 **RetainPDF 管线**
（`retainpdf-pipeline` 4.2.6，MIT，随包内置 ~286MB）。上游管线以
`document.v1.json` 为翻译输入、Typst 重排输出，支持扫描版与公式直通；
其 `generic_flat_ocr` 适配器使智阅无需任何云 OCR 即可喂入自有文字层/本地 OCR。

**集成形态**（引擎细节见 `rust/src/translate/`）：
- **vendoring**：`third_party/retainpdf/`（pipeline 源码 + 宋体 + PIN，钉提交 d365ed8）
- **引擎目录**：`scripts/build_retain_engine.sh` 组装独立 CPython 3.11 + site-packages
  （Pin 依赖：Pillow/PyMuPDF/pikepdf/requests/urllib3）+ Typst 0.15.1 + `@preview`
  cmarker/mitex + 字体 + `engine.json`；随包内置（`<exe_dir>/retainpdf`），开发用
  `RBWA_RETAIN_ENGINE_DIR` 指向组装目录
- **输入桥**（新 `flat_ocr.rs`，旧管线 `extract.rs` 聚类代码移植）：文字层
  （pdfium 字体元数据）与本地 OCR 两条路径 → 扁平块（heading/body/abstract/
  caption/footnote/header/footer + 整段公式）→ `generic_flat_ocr` JSON
- **运行器**（重写 `job.rs`）：两步 CLI（`normalize-ocr` → `book`），stdout JSONL
  进度映射（解析版式/翻译中/排版输出），取消杀进程，产物安装为
  `translated/{book_id}/translated.pdf` + manifest（`BookTranslation` 模型不变、
  FFI 签名不变、无需 codegen）
- **术语表**：接入引擎 `glossary_entries`（level=preferred）
- **移除**：BabelDOC 下载器/安装器（engine.rs 从 1126 行缩至 ~250 行）、
  设置页下载/卸载 UI

**验证**（全零真实 API）：
- Rust 106 测试 + clippy 干净；`flat_ocr` 含真实 PDF 集成测试（pdfium 造两页版面，
  断言标题/图注/公式分类、页眉页脚与页码剔除、段落合并、bbox 在页内）
- **端到端**（`#[ignore] translate_book_end_to_end`）：临时 DB + 夹具书 + mock LLM
  （`scripts/dev/mock_llm.py`，理解管线四种协议）+ **真实 Python 管线**，断言
  2 页 1:1、译文进入 PDF、事件流有翻译中与终态成功
- 零 LLM 冒烟：Rust 桥产物 → `normalize-ocr` 校验 → `render-only` overlay 产出
- Flutter 192 测试全绿、`flutter analyze` 0

**已知边界（v1）**：目标语言固定简体中文（上游硬编码）；整本粒度（随进度/手动
待后续）；无 dual 并排导出（窗格渲染单 PDF）；引擎不可应用内卸载（随包内置）。

**docs 同步**：FEATURES §7.4、THIRD_PARTY §2（含 PyMuPDF AGPL 独立进程登记）、
ARCHITECTURE `translate` 行、README 概览。

---

### 3.19 修复：评审门禁对续接单元成员的截断误判（2026-10-07）

**现象**：整本翻译在**全部批次翻完后**报错，界面只有
`引擎退出码 1：translation/python_unhandled_exception: 任务失败，但暂未识别出明确根因`，
不产任何产物。用户实跑 10 页文档（6 处）与 88 页论文（4 处）均复现。

**根因（上游 4.2.6 缺陷，已用实跑数据实锤）**：评审的截断检查
（`quality._truncated_translation_issue`：源文 ≥200 字符且译文 <15%）在
`review_translation_item` 里拿 `unit_source_text(item)` = **续接单元合并全文**
比对 `item["translated_text"]` = **条目自身的片段译文**。跨页续接单元的小成员
必然误判（如 887 字符单元中的 86 字符片段 → 0.097 < 0.15）；用户 10 页文档的
6 个被拦条目全部是 `route_path: continuation_group_members`，其中 `p009-b000`
源文 28 字符、译文 56 字符（比值 2.0）也被判"截断"——只有单元口径才可能触发。
门禁 `enforce_no_blocking_review_errors` 全有或全无：一个误判让整本任务作废。

**补丁**（vendored 管线，记录见 `third_party/retainpdf/PIN.md` §本地补丁）：
`patches/0001-truncation-item-scope.patch` —— 截断检查改用**条目级源文**
（`protected_source_text`/`source_text`，缺省回退调用方口径）；其余检查
（占位符/公式/上下文泄漏）不变。

**错误呈现**（`rust/src/translate/job.rs`）：`structured_failure_summary`
优先取 `detail`（真实原因）而非通用 `summary`，并按字符边界截断到 400 字符；
上游的"未识别出明确根因"不再掩盖门禁信息。

**验证（全零 API）**：mock 端到端重跑——88 页论文 27.2s 通过（修复前必挂）、
用户 10 页文档 5.8s 通过；Rust 107 测试 + clippy 0；AppImage 重打供实机复验。
测试框架新增 `RBWA_E2E_BOOK_PDF`（用外部 PDF 做规模复现，仅 mock、无真实端点）。

**遗留**：门禁对**其他** error 类（真截断/英文残留等）仍是全有或全无——
单条目判死整本在桌面场景代价大，是否放宽需另行决策；已具备向
<https://github.com/wxyhgk/retain-pdf> 提 issue 的最小复现材料。

---

### 3.20 译文页选中与 AI 划词（2026-10-08）

**需求（7.4.10）**：对照窗格里的译文要能像原文一样划词后使用 AI 动作
（翻译 / 解释 / 搜索）与复制。前提成立：引擎产出的是矢量文本 PDF（实测
每页可提取词框，如用户译本第 3 页 155 词/1125 字符）。

**实现**（复用现有选中机制，无新交互范式）：
- Rust：`pdf::extract_text_file`（任意 PDF 文件的字符框提取，归一化同
  `extract_text`）+ FFI `extract_translated_text(book_id, page)`（读
  manifest 的 mono_path，spawn_blocking 提取）；FRB codegen 同步
- Dart：`translated_char_box_cache.dart`（8 页 LRU，监听
  `translationRevisionProvider`——译本出现/更换/删除自动失效）
- `SelectionLayer` 增 `translated` 模式：boxes 来自译文缓存、选中带
  `SelectionSource.translated`、tap 不触发标注/OCR 修正
- `Selection` 模型增 `source` 字段（默认 original，向后兼容）
- `FloatingToolbar` 按来源缩减：译文选中只显示 翻译/解释/搜索/复制
  （文本层标注锚定原文的标注库，译文侧不提供——如实不虚标）
- 译文页卡片：LayoutBuilder 计算 contain 的实际显示矩形，选中层与其
  精确对齐（归一化字符框坐标才不会偏移）
- 测试：Rust `extract_text_file` 归一化单测（pdfium 造页）；Dart
  `translated_selection_test.dart`（两种来源的按钮集合断言）；
  Rust 108 + Flutter 194 全绿、analyze/clippy 0

**修复（同日，几何回归）**：选中层最初用 `Positioned.fill` 铺满卡片，而译文图
像是 `BoxFit.contain` 居中后的更小矩形（含留白）——两者坐标系不同尺度，导致
选中框与文字错位、行首行尾多选/少选（标题上尤其明显）。改为在 contain 的实际
显示矩形内叠放图像与选中层（`Align(topCenter)+SizedBox(fitted)`），并新增几何
回归测试（断言选中层矩形与图像矩形完全重合；已验证旧实现下必然失败）。同时确认
pdfium 对该矢量 PDF 的**逐字框本身准确**（等宽步进、连字符高度正确），错位来源
只在坐标系映射。

**已知边界**：译文的选中是「按显示文本」选中（选中的是译文自身文字，
不是原文对应段）；`中英互译`目标下对译文再按「翻译」会翻回中文——这是
AI 动作的正常语义。

---

### 3.21 译文页标注全量开放（窗格隔离，schema v9）（2026-10-08）

**需求**：译文页也要能用下划线 / 高亮 / 删除线 / 笔记（此前只开放 AI + 复制）。

**数据模型（schema v8 -> v9）**：`annotations` 增 `source TEXT NOT NULL
DEFAULT 'original'`（'original' | 'translated'）。两栏页号相同，靠窗格标签
而不是新表/新书来隔离；旧行读作 'original'（迁移测试覆盖：既有标注存活）。

- Rust：`TextAnnotation.source`；repo SELECT/INSERT 带 source；FFI
  `create_annotation(..., source)`（FRB codegen 同步）；导出标注时译文条目加
  「（译文）」；迁移 v8->v9 + 单测
- Dart：`AnnotationPane` 枚举与透传；**原文页只渲染/命中 source=original**
  的标注，译文页只渲染 source=translated；译文页加 `HighlightLayer`（与选中层
  同矩形）；`SelectionLayer` 在译文模式恢复标注点按（OCR 低置信修正仍仅原文）；
  工具栏恢复全量 8 按钮，创建标注按选中来源写 pane；标注列表对译文标注加「译」徽标
- 验证：Rust 110 测试 + clippy 0；Flutter **199 测试** + analyze 0（新增：译文
  选中 8 按钮断言、窗格隔离断言、译文页油漆层断言、几何回归）

**已知边界**：删除/重新翻译译本不影响已建标注（坐标按页保存，译本回来即再显示）；
译文标注不参与原文页的检索/命中高亮（本质是两套文本）。

---

### 3.22 性能优化：译文渲染管线 + 引擎缓存（2026-10-08）

体检发现三处拖累"流畅度"的实现，逐一修复：

**① 译文页图像无界驻留 + 过采样渲染**（最大头）
- 旧：`translatedPageImageProvider` 为非 autoDispose 的 family，**翻过的每页
  解码图像永久驻留内存**；且固定 `dpi 3.0`（A4 ≈ 1785×2526 ≈ 4.5MP/页），
  与窗格实际显示宽度（常仅 ~700px）无关。
- 新：`translated_bitmap_cache.dart`（同构于原文页的 `bitmap_cache`）——按
  **显示宽度分档**（256px 桶，`render_translated_page` 改收 `target_width_px`，
  Rust 侧按页宽换算 scale 并钳制 0.5–4.0）渲染，像素量降 3–5 倍；LRU 12 条且
  **淘汰时 dispose ui.Image**（原文缓存只删引用不 dispose，靠 finalizer）；
  provider 改 `autoDispose`，内存随视口而非全书增长；译本变更（revision）整缓存清空。
- 并发同键渲染去重（ListView 一帧多次请求共享一次 Rust 渲染）。

**② 引擎状态探测全目录遍历**
- 旧：`get_engine_status` → `engine_disk_usage` 每次**走 300MB/数万文件树**，
  且是同步 FFI，打开设置页卡 UI。
- 新：构建时把 `size_bytes` 写进 `engine.json`（两个打包脚本），状态直接读清单；
  无该字段的旧清单回退为**每进程一次**遍历（`OnceLock` 缓存）。

**③ 翻译无跨次缓存**
- 旧：`OUTPUT_ROOT` 在随任务删除的 job 目录里 → 重试/重译**重新支付全部 LLM 调用**。
- 新：每书持久 `{data_dir}/retain_output/{book_id}`（管线的翻译单元缓存/领域缓存/
  排版记忆跨次命中）；`enforce_output_cache_cap` 全局 2GB 上限按 mtime 驱逐
  （跳过 pinned/在飞）；删书级联清理；artifact LRU 驱逐时同步清理。

**验证**：Rust 111 测试（新增 manifest 体积优先、输出缓存目录）+ clippy 0；
Flutter 201 测试（新增宽度分档单测）+ analyze 0；mock 端到端 6.4s 通过。

---

### 3.23 Android v1：内置 OCR 随包 + 文本级对照（2026-10-20）

按 [`ANDROID_V1_PLAN.md`](ANDROID_V1_PLAN.md) 的 A0–A5 实施。桌面路径不变；
Android 走独立的平台能力层与文本翻译模块。

**构建链（A0）**
- 新增 `android/` 工程（applicationId `work.csywxk.icefish_zhiyue`，minSdk 26 /
  targetSdk 35 / **仅 arm64-v8a**）。
- `cargo-ndk` 交叉编译 `librbwa_core.so`；pdfium 用 bblanchon `chromium/8111`
  Android arm64（`scripts/fetch_pdfium_android.sh`）。
- **实测**：arm64 release APK **285.4MB**（含 210MiB 两套 OCR 模型），
  `zipalign -c -P 16` 通过；`pdfium / librbwa_core` 的 LOAD 段均 0x4000 对齐。
- **x86_64 Android 不可用**：`ort-sys` 无该目标预编译（OCR 依赖 ORT），v1
  收敛为 arm64；模拟器需 arm64 系统镜像。

**初始化与原生路径（A1）**
- 新增 FFI `init_core_with_data_dir`（Android 无 XDG data dir，进程 CWD 为 `/`）。
- 新增 FFI `configure_native_library_dir`：`current_exe()` 在 Android 指向
  `app_process`，pdfium 改为按 `nativeLibraryDir` 绝对路径绑定。
- OCR `model_root()` 在 Android 只认 `{data_dir}/models`（模型由 Kotlin 安装器
  从 assets 解压）；推理参数移动端收敛：`max_side_len` 1280、batch 4、线程 2–4。

**OCR 随包内置（A2）**
- `scripts/stage_android_models.sh`：把快速 + 高精度两套模型（≈210MiB）连同
  sha256 清单放进 `assets/models/`；`noCompress` 避免二次压缩。
- `ModelProvisioner.kt`：首启流式复制（8KiB 缓冲）、逐文件 sha256、`.tmp` +
  rename、空间检查（350MB）、断点重试、进度回调；完成后写 marker。
- Dart `_Bootstrap` 在安装期间显示进度页，可重试 / 跳过。

**触屏适配（A3）**
- 手机断点 `<700dp`：侧栏 / AI 面板改全屏覆盖，对照改「原文 / 译文」分段切换；
  `PopScope` 让返回键逐层关闭面板。
- 选区：移动端改**长按起选 + 拖动扩展**，普通拖动留给滚动；桌面仍为拖选。
- 缩放：双指捏合 + 双击（1.2 ↔ 2.0），桌面 Ctrl+滚轮不变。
- 标题栏：移动端隐藏窗口控制按钮，仅保留返回与标题。

**文本级对照（A5）**
- `flat_ocr::build_page_blocks`：按页提取（邻页仅用于页眉页脚判定），
  整本构建改为调用它。
- `translate/text_translate.rs`：块级 LLM 翻译——每批 ≤12 块 / 6k 字符、
  JSON 严格对齐（忽略伪造 index）、缺块单块重试、401/403 不重试、429/5xx
  退避、取消检查、公式与短文本跳过、页面字符预算 40k。
- 缓存：schema **v9→v10** 新表 `page_text_translation`（书/页/块/目标语言唯一，
  含 source_hash 与 model，整页事务替换）；删书级联。
- 注入防御：块文本经 `sanitize_untrusted` + 每请求随机 nonce 边界包裹，系统
  提示声明「边界内是待翻译数据」，返回只接受 JSON 结构与已知块号。
- FFI：`get_page_text_blocks` / `get_page_text_translation` /
  `translate_page_text` / `cancel_page_text_translation` /
  `clear_book_text_translation` / `count_text_translated_pages`。
- Dart：文本对照 provider（缓存优先、当前页翻译、后 2 页串行预取）、
  块列表 UI（译文为主、原文折叠、公式徽标、失败重试）。

**验证**：Rust 136 测试全绿（新增缓存/解析/归一化/跳过规则）；Flutter 240
测试全绿（新增 7 个文本翻译测试）；`flutter analyze` 0；Android debug/release
APK 构建与 16KB 对齐通过。

**已知边界**：文本对照只覆盖 PDF（含扫描页）；图片书仍只做 OCR + 划词；
移动端默认快速 OCR；Play 分发需改用 install-time asset pack（当前 APK 内嵌）。

### 3.24 Android 交互修正：返回手势与书籍长按（2026-10-20，1.0.1）

**① 返回手势直接退出应用**
- 根因：所有页面跳转用 `context.go(..)`，go_router 会**替换**当前路由，
  导航栈始终只有一页；系统返回手势调用 `Navigator.maybePop()` 得到 false，
  系统随即关闭 Activity。
- 修复：详情页（阅读器 / 设置 / 全文搜索 / AI 对话）改 `context.push(..)`，
  返回手势与页面返回按钮都变成「弹出一层」。新增
  `lib/core/navigation.dart::navigateBack()`：能 pop 就 pop，深链等无栈场景
  回退到书库，而不是让系统退出。
- 书库双击打开加了 400ms 去重（`push` 不再像 `go` 那样自动合并重复路由）。

**② 书籍长按无法弹出菜单**
- 根因：卡片外层是 `LongPressDraggable`（200ms 触发），领先 `InkWell` 的
  500ms 长按，手势竞技场被拖拽赢得，`onLongPress` 永不触发。右键菜单在触屏
  上也无从触发。
- 修复：`BookTile` 新增 `enableDrag`，移动端默认关闭拖拽包装（长按 → 底部菜单：
  打开 / 收藏 / 分配到分类… / 删除）；桌面保留拖拽归类，右键菜单不变。
  分类仍可从菜单里的「分配到分类…」完成。

**③ 顺带修正的手机布局**
- 书库左侧 220px 分类栏在手机上把网格挤到不可用：窄屏（<700dp）改为 Drawer，
  工具栏左侧加汉堡按钮；平板 / 桌面保持常驻栏。

**验证**：新增 `navigation_test.dart`（pop / 无栈回退）与书库长按测试；
Flutter 243 测试全绿、analyze 0；release APK 1.0.1 构建通过、16KB 对齐通过。

### 3.25 流畅度优化 + 动态刷新率（2026-10-20，1.1.0）

**① 动态刷新率（30–120Hz）**
- 新增 `DisplayRefreshBridge.kt`（`rbwa/display` 通道）：Android 11+ 用
  `Surface.setFrameRate(fps, compatibility, ONLY_IF_SEAMLESS)` 做**逐表面提示**，
  不触发模式切换；API 30 用两参重载；更旧版本回退
  `WindowManager.LayoutParams.preferredRefreshRate`。请求值先按面板实际支持的
  mode 就近取整（兼容 59.94 / 119.88）。
- 新增 `core/platform/refresh_rate.dart`：活动（触摸 / 滚动 / 指针信号）时请求
  面板最高档（上限 120），静置 900ms 后降到 30Hz。`MaterialApp.router` 的
  `builder` 包一层 `RefreshRateScope`，全应用生效、无需逐页面接线。
- **能力边界**：应用无法渲染超过面板刷新率；静止时 Flutter 不产帧，LTPO 面板
  本身会降频，该提示主要用于避免被钉在高档位。

**② 阅读页重绘边界拆分（主要卡顿源）**
- 旧：整页一个 `RepaintBoundary`，位图上的主题滤镜（`ColorFiltered`，会强制
  `saveLayer`）与所有矢量层混在一起 → 选区拖动的每一帧都重绘数兆像素的页面。
- 新：位图单独一层，全部矢量覆盖层（高亮 / 低置信 / 搜索命中 / 选区 / 图片标记
  / OCR 提示）共用一个子层。拖动选区只重绘矢量层。

**③ 位图内存与渲染分辨率**
- `LruCache` 增加**字节预算**（`maxBytes` + `sizeOf`），与条数上限共同淘汰；
  移动端预算 96MB、桌面 192MB（此前固定 20 条，A4 高 DPI 下可达 180MB+）。
  淘汰时**不主动 dispose**：列表可能仍在绘制该 `ui.Image`（会抛异常），
  由引擎在最后一个引用释放后回收。
- Rust `render_page` / `render_image` 增加**单页像素上限**（Android 12MP ≈ 48MB
  RGBA，桌面 40MP）：4× 缩放 × 3× DPI 的 A4 原本要 285MB，现在按比例缩小，
  长边仍远超屏幕可分辨密度。

**④ 滚动预取与流式节流**
- 单页 / 双滚动列表 `scrollCacheExtent` 设为约一页高度（默认 250px 不足一页，
  快速滚动会露出占位图）；双页翻页开启 `allowImplicitScrolling`，相邻跨页预渲染。
- `AiStreamSession` 的 `onUpdate` 节流到 80ms：此前每个 token 都触发一次
  Markdown 重建，流式回答期间掉帧明显；结束时仍交付完整文本。

**验证**：Rust 139 测试（新增像素上限 3 个）+ clippy 0；Flutter 251 测试
（新增 LRU 字节预算 6 个、刷新率策略 2 个）+ analyze 0；release APK 1.1.0
构建通过、16KB 对齐通过。

### 3.26 Android 触屏 P0：手机布局与触控修复（2026-10-20，1.2.0）

按 [`ANDROID_TOUCH_OPTIMIZATION_PLAN.md`](ANDROID_TOUCH_OPTIMIZATION_PLAN.md) 的 P0 实施。

**① 选区工具条崩溃（P0 最高优先级）**
- 根因：`FloatingToolbar` 按 `_estWidth = 760` 估算定位，
  `clamp(8, screen.width - 768)` 在 360dp 屏上上界为负，Dart `clamp` 抛
  `ArgumentError` —— 长按选词弹出工具条即崩溃。
- 修复：浮动定位改为 `CustomSingleChildLayout` + 实测子尺寸，clamp 前判断
  `maxLeft < 8` 直接左对齐；手机改为**底部固定 4×2 网格**（每格 48dp），
  平板/桌面保留可拖动浮条。笔记编辑器在手机上也改为底部停靠，键盘弹出时
  用 `viewInsets` 顶起。

**② 手机阅读 chrome**
- 新增 `phone_reader_chrome.dart`：顶部条（返回 / 书名 / 页码跳转 / 更多）+
  底部 5 项操作栏（缩略图 / 目录 / 批注 / AI / 更多）+ 更多面板
  （单页模式、缩放、对照、识图、标注、跳转）。
- 桌面 `ReaderToolbar` 约 700dp 宽，360dp 屏必然溢出；现在按
  `PlatformCapabilities` + 断点分叉，桌面布局不变。

**③ 窄屏模式收敛**
- 手机（<700dp）自动把双页/双滚进度降级为单页，更多面板里的模式选择器
  也只提供单页，并说明原因。

**④ 其余窄屏布局**
- 书库工具栏：搜索框弹性填满，全文搜索 / 主题 / 设置收进溢出菜单。
- 结果卡：手机改为底部停靠面板（60% 屏高，随键盘顶起），桌面保留可拖拽浮卡。
- 「AI 对话」页：手机为「列表 → 详情」两级导航 + 返回条，桌面保持 280dp 分栏。
- 批注工具条：手机用 `Wrap` 自动换行，不再单行溢出。
- 收藏按钮：视觉仍是 20dp，命中区扩到 48×48。

**验证**：新增 `phone_layout_test.dart`（360×780dp：书库工具栏无溢出、
收藏按钮 ≥48dp、选区工具条停靠且不抛异常、设置行满宽）；Flutter **255**
测试全绿、analyze 0；release APK 1.2.0 构建通过、16KB 对齐通过。

### 3.27 Android 触屏 P1：选区手柄、系统集成与移动手势（2026-10-20，1.3.0）

**① 词级选中 + 起止手柄**
- `selection_geometry.dart` 新增词边界判定：CJK（含假名 / 谚文 / 全角标点）
  按**单字成词**，拉丁按字母/数字/撇号/连字符成词；标点与空白只选中自身。
- 长按改为选中**整个词**并触发 `mediumImpact` 震动；拖动时选区从首个词
  延伸到指针下的词（锚点词不会被缩成单字）。
- 选区两端各有一个手柄（14dp 圆点 + 40dp 命中区），拖动按词调整起止点，
  可反向拖动；手柄用 `globalPosition` 换算到页面坐标（避免用自身 40dp
  盒子的局部坐标）。
- 双击文字选中该词；双击空白保留原来的缩放切换。

**② 触觉反馈**
- 新增 `core/haptics.dart`（tap / select / success / warning 四档，桌面空转）。
- 接入：翻页（仅在页码真的变化时）、长按选词、OCR 成功/失败、翻译成功/失败。

**③ 边缘翻页与 chrome 开关**
- 选区层把未被消费的点击（正常点击空白）上报 `readerTapProvider`：
  左 18% 上一页、右 18% 下一页、中部切换手机 chrome 显隐（180ms 滑动淡出）。
- 用 provider 上报而非层层回调，页面/滚动/页项均无需改签名。

**④ 沉浸模式与常亮**
- 阅读页进入时 `immersiveSticky`（隐藏系统栏）+ `FLAG_KEEP_SCREEN_ON`，
  离开时恢复 `edgeToEdge` 并清除常亮。

**⑤ 从其他应用导入（ACTION_VIEW / ACTION_SEND）**
- Manifest 增加 `application/pdf` 与 `image/*` 的 VIEW / SEND 过滤器。
- `SystemBridge.captureIntent` 把 `content://` 流式复制到
  `cacheDir/incoming/`（content URI 不可当文件路径用，授权也不跨进程存活），
  冷启动与 `onNewIntent` 热启动都覆盖；Dart 启动时取走并调用现有导入流程，
  SnackBar 汇报结果。

**⑥ 内存压力接线**
- `main.dart` 用显式 `ProviderContainer` 订阅 `onTrimMemory`：
  `BitmapCache.trim(keepPage:)` 释放非当前页位图，同时清 `imageCache`；
  临界级别再 `clearLiveImages()`。

**⑦ 后台治理**
- 应用进入后台：刷新率控制器立即降档。
- 对照翻译的预取在每一轮前检查生命周期，后台不再发起 LLM 请求。

**验证**：新增 `word_selection_test.dart`（9 个：CJK/拉丁/标点/连字符/
OCR 行内/编码位置）与 `reader_tap_test.dart`（2 个：分区边界、seq 单调）；
Flutter **266** 测试全绿、analyze 0；Kotlin 编译通过；release APK 1.3.0
构建通过、16KB 对齐通过，`aapt2` 确认 VIEW/SEND 过滤器已打包。

### 3.28 Android P2：渲染调度、DPI 分档与书库多选（2026-10-20，1.4.0）

**① 消除每页的双重渲染（收益最大）**
- 根因：缩放分档用 `round()`，默认 1.2× 先落到 1.0× 渲染，随后 `_maybeSharpen`
  发现不够清晰又按 1.5× **重渲一次** —— 每页首次显示都付两次 pdfium 渲染
  加两次 RGBA 解码。
- 修复：分档改为 `ceil()`，首次即落在最终档位；sharpen 对常见缩放成为空操作。

**② 优先级渲染队列**
- `BitmapCache` 内建串行队列（pdfium 本来就有全局锁）：可见页 priority 0、
  相邻页/缩略图 priority 1，同级 FIFO；若某页排队期间变为可见，
  `_promote` 会把它提到最前。快速滚动时阅读页不再排在一串预取之后。

**③ 自适应渲染 DPI**
- 新增 `effectiveRenderDpi(deviceDpr, zoom)`：`zoom ≤ 1.4` 时把渲染 DPI
  钳到 2.0，`> 1.4` 恢复设备 DPR（细节阅读仍清晰）。
- 手机 DPR 2.75–3.5 时，A4 页从约 26MB 降到约 12MB，浏览态缓存能多放
  2–3 页，翻页更少触发重渲。

**④ 书库多选**
- 新增 `librarySelectionProvider`（active / ids）+ 底部操作栏：批量收藏、
  批量分类（底部选择表）、批量删除（一次确认）。多选期间隐藏导入 FAB、
  卡片显示勾选徽标、拖拽禁用。
- 入口在书籍长按菜单的「多选」（用户此前要求长按弹菜单，故不改成
  长按直接多选）；选择集随书库刷新自动收敛。

**⑤ 音量键翻页**
- 手机端 `volumeDown` → 下一页、`volumeUp` → 上一页；输入框或笔记编辑器
  聚焦时不拦截，避免影响正常调音量。

**验证**：新增 `render_tuning_test.dart`（5 个：ceil 分档、范围钳制、DPI 三档）
与 `library_selection_test.dart`（4 个：开始/切换/收敛/清空）；Flutter **275**
测试全绿、analyze 0、图标守卫通过；release APK 1.4.0 构建通过、16KB 对齐通过。

### 3.29 主界面布局重排：黄金比例与节奏（2026-10-21，1.5.0）

主界面（书库）此前的参数各自独立：220px 侧栏、180px 卡片、12px 间距、
3:4.4 封面、44dp 页头。改为一套共享比例的度量体系。

**度量体系**（`lib/core/theme/layout_metrics.dart`）
- **φ 用于比例**：卡片封面按黄金矩形（宽:高 = 1:1.618）；侧栏宽度取窗口的
  φ⁴ 细分并钳在 208–264dp，窗口变宽时侧栏只微增，不会变成第二内容列。
- **斐波那契用于间距**：8 / 13 / 21 / 34 / 55 / 89（相邻步长 ≈ φ，误差 ≤8%），
  4 明确保留为 4dp 栅格单位而非冒充 φ 阶梯（测试守卫生效时抓到过这一点）。
- **网格按列求解**：列数由目标卡宽 ~168dp 反解（不再用
  `MaxCrossAxisExtent`，那会留下参差的末列）；窗口变宽→**加列**而非放大卡片。
  单元格高度 = 卡宽/φ + 64dp 元信息条，行底不再留空。

**页头重做**
- 左侧「我的书库 + 共 N 本 / 筛选出 M 本」，右侧搜索框（320dp），搜索从
  "页面标题"变为"页面工具"。
- 三档自适应：≥900dp 完整（标题+搜索+三按钮）；560–900dp 标题+260dp 搜索
  + 溢出菜单；<560dp 仅搜索+菜单。
- 页头 64dp（40×φ），用 1px 分隔线代替阴影——与内容同纸张，深度靠线不靠高程。

**卡片重做**
- 去掉 `Card` 的阴影，改为同纸面色 + 1px 描边 + 13dp 圆角：封面成为视觉主角。
- 页码从封面上的黑色角标移到元信息条（可读性更好，不压图）。
- 收藏态用右上角小圆徽标；多选态勾选在左上角，两者不冲突。

**空状态**：圆形底 + 128dp 焦点、34/13/21 节奏、两段文案（导入 + 长按提示）。

**真机截图发现并修复的两个真问题**
1. **侧栏压在状态栏下**：`Row(rail, Scaffold)` 在 Scaffold 之外，边到边模式下
   没有消费者吸收系统栏 inset；补 `SafeArea(bottom: false)`。
2. **页头标题被挤成 0 宽**：原判断用窗口宽度 776dp，但侧栏占了 208dp，页头
   实际只有 568dp；改为传 `availableWidth` 并按实际宽度选档。
3. 网格内边距也误用内容宽度判档，导致平板被当手机给 13dp；改用窗口宽度。

**验证**：新增 `layout_metrics_test.dart`（8 个：φ 关系、斐波那契阶梯、
手机/平板/桌面列数、退化宽度、单元格几何、侧栏范围）与平板尺寸 widget 测试
（1600×2560 @2.0 = 800×1280dp，断言无溢出 + 侧栏/页头存在）；
Flutter **284** 测试全绿、analyze 0；在小米平板 25091RP04C（776dp 宽）上实机
安装截图确认：3 列、卡片 149dp、封面比例 0.62、侧栏 208dp、页头中档布局。
release APK 1.5.0 构建通过、16KB 对齐通过。

### 3.30 主界面视觉重构：参照同类产品的设计语言（2026-10-21，1.6.0）

参考 `screenshot/` 中同类阅读器的 7 张截图（本地参考图，不入库），重做主界面。目标不是照搬，而是
把它成立的设计决策吸收进现有架构。

**① 悬浮双面板 shell**（`floating_panels.dart`）
- 侧栏与内容区是两个独立的圆角面板（18dp 圆角 + 一道柔和投影），浮在窗口
  背景上，中间 8dp 缝隙。原来是一个贴边的 Row + Scaffold。
- 手机没有放两个面板的宽度：侧栏进抽屉，内容面板单独铺满。

**② 侧栏三段式**（`category_rail.dart` 重写）
- 顶部「导航 / 文件夹 / 标签」胶囊切换，下面是对应列表。
- 导航：所有文档 / 最近使用 / 我的收藏 / PDF / 图片 + AI 对话 / 全文搜索 / 设置。
- 文件夹：用户分类（拖放目标 + 长按重命名删除），底部「新建文件夹」。
- 标签：明确说明未支持多标签并引导用文件夹，而不是做一个假的空列表。
- 选中项是整圆胶囊高亮（`primaryContainer` 55%），不再用 ListTile 的矩形底。

**③ 顶部胶囊筛选栏**（`library_filter_bar.dart`）
- 44dp 高的分段控件：全部 / 最近 / PDF / 图片 / 收藏（+ 当前文件夹时多一项），
  右侧显示结果数量。与侧栏共用 `libraryFilterProvider`，两侧永远同步。
- 新增 `LibraryView.recent` 视图（按已有 `lastOpenedAt` 过滤）。

**④ 书卡去掉所有容器**（`book_tile.dart` 重写）
- 移除 `Card`、描边、内边距：只剩圆角封面 + 下方两行文字，靠投影从面板上浮起。
- 标题改**衬线斜体**（`fontFamily: 'serif'` + italic），这是参考设计最鲜明的
  特征，也让书脊感和正文阅读感区分开。
- 收藏改为**心形**、放在封面**右上角**（原为右下角星形）；未收藏时是白色
  描边心 + 轻阴影，收藏后填玫红色。仍保留 48dp 命中区。
- 元信息合并为一行：`26/06/29 · 575 页`；读过则变成
  `26/06/29 · 已读 128 / 575`，读完显示 `已读完`。日期取自最近打开时间，
  回退到导入时间。
- 封面用 `BoxFit.contain`（此前 `cover` 会裁掉书页边缘文字），空隙填面板色。

**⑤ 移除旧组件**
- `library_toolbar.dart` 删除（被面板内的 `_PanelHeader` 取代）；AppBar 的
  高程和内部分隔线一并去掉——面板本身已是抬升面，再画线是双重分隔。

**验证**：新增 `library_design_test.dart`（4 个：双面板结构、手机单面板、
书卡无 Card 容器且标题衬线斜体、筛选栏五个胶囊）；改写侧栏与筛选测试以匹配
新结构；Flutter **294** 测试全绿、analyze 0、图标尺寸守卫通过；
release APK 1.6.0 构建通过、16KB 对齐通过。

**说明**：参考设计里的「笔记 / 标签」依赖多标签数据模型，本项目 schema 只有
单层分类，因此标签页如实说明未支持，而不是展示不可用的界面。

### 3.31 书卡尺寸统一（2026-10-21，1.6.2）

**现象**：同一行里两本书的封面大小不一致（用户截图：Agent 明显比 3D数学基础窄矮）。

**根因（两层）**
1. 封面用 `Expanded` 占剩余空间，文字块高度随标题行数变化：一行标题时封面比
   两行标题时高约 18dp。
2. 封面用 `BoxFit.contain`，比例不同的图片会留黑边，视觉宽度随之不同。

**修复**
- 封面改为 **`AspectRatio(coverRatio)`**：高度只由宽度和 √2 比例推导，标题
  行数再也影响不到它。
- 文字块预留**固定两行标题高度**，元信息行（日期 · 进度）因此在每张卡上
  落在同一基线（此前 `Spacer` 让一行标题的卡片把元信息推到底部）。
- 封面改 `BoxFit.cover` + `Alignment.topCenter`：填满槽位，顶对齐保留书名/首页
  抬头不被裁掉。
- `Golden.textBlockHeight` 与 `cellHeightFor` 共用同一公式，并留 2dp 余量吸收
  字体 ascent/descent 溢出（真机上曾报 0.98px overflow）。

**验证**：新增 `book_card_size_test.dart`（4 个：真实 `BookGrid` 下两本书封面
矩形完全相等、√2 比例、1.3× 字号缩放不挤压封面、无溢出）与度量测试补充
（cell = cover + text block、文本块随缩放在单元格同步增长）；Flutter **300**
测试全绿、analyze 0；平板实机截图确认两卡封面 195×276（比例 0.707）、
元信息基线对齐、无溢出标记。release APK 1.6.2 构建通过、16KB 对齐通过。

### 3.32 弹层视觉统一：对话框 / 底部面板 / 菜单（2026-10-21，1.7.0）

**问题**：主界面已经改成悬浮圆角面板，但弹出框仍是 Material 默认样式——
`AlertDialog` 的 28dp 圆角、`showModalBottomSheet` 的贴边直角、`PopupMenu`
的高程阴影，看起来像另一个产品塞进来。

**① 新增弹层设计系统**（`core/widgets/app_overlay.dart`）
- `AppDialog`：18dp 圆角 + 面板底色 + 发丝描边 + 柔和投影；**衬线标题**
  （与书库页头一致）、可选副标题/正文/图标、右下药丸按钮组。
- `AppDialogAction`：药丸按钮（`StadiumBorder`），支持 primary / destructive。
- `AppSheet`：顶部 18dp 圆角 + **抓取条** + 衬线标题行 + 可关闭按钮，内容区
  可滚动，间距走斐波那契阶梯。
- `AppSheetItem`：复用侧栏的整圆胶囊行（选中为 `primaryContainer` 55%），
  带图标 / 尾部说明 / danger 态。
- `showAppSheet()`：透明宿主 + 遮罩色 0.42，让 `AppSheet` 自己画面板
  （有色的宿主会把圆角画成双层）。

**② 全局主题统一**（`AppTheme._base`）
- `popupMenuTheme`：面板色 + 18dp 圆角 + 透明 surfaceTint，去掉 Material 默认
  的硬阴影环。
- `bottomSheetTheme`：宿主透明、无高程，避免与 `AppSheet` 的双层圆角。
- `dialogTheme`：面板色 + 18dp 圆角。
- `snackBarTheme`：**floating** 药丸条（原为通栏），不遮挡书架与阅读器 chrome。
- `chipTheme` 全胶囊、`dividerTheme` 统一发丝线、`tooltipTheme` 同半径、
  `sliderTheme` 主色轨道——避免各页面各自为政。

**③ 逐个改造**
- 确认框 / 文本输入框 / 分类选择对话框 → `AppDialog`；输入框改圆角填充
  样式（与页头搜索框一致），不再是 `OutlineInputBorder`。
- 书卡长按菜单、文件夹长按菜单、批量分类选择 → `AppSheet`；
  文案「分配到分类…」统一为「移动到文件夹…」，与侧栏「文件夹」用语一致。
- 阅读器「更多」面板 → `AppSheet`；缩放/视图模式各自成 sheet（原来挤在
  一个面板里的横向控件行）。

**验证**：新增 `overlay_style_test.dart`（5 个：token 共享、确认框不用
`AlertDialog` 且标题衬线、输入框圆角填充、sheet 面板半径、主题覆盖
popup/snackbar/bottomsheet/chip）；Flutter **305** 测试全绿、analyze 0；
平板实机截图确认底部面板（抓取条 + 衬线标题 + 胶囊行）与「移动到文件夹」
对话框（18dp 圆角 + 药丸按钮 + 选中胶囊）均与主界面同源。
release APK 1.7.0 构建通过、16KB 对齐通过。

### 3.33 代码优化：重建循环、重复扫描与请求竞态（2026-10-21，无版本变更）

一次面向运行时热点的梳理，不新增功能。

**① 书库多选的逐帧重建循环（收益最大）**
- `LibrarySelectionState` 没有值相等：`BookGrid` 每帧在 post-frame 里调用
  `retain()`，每次都发布新状态对象，Riverpod 无法抑制通知 → 书库在多选
  状态下永久重建。补 `==` / `hashCode`（`setEquals`），并让 `retain()` 在
  选中集未变化时直接返回。
- `Reloadable.reload()` 不再无条件切到 `loading`：刷新期间保留旧列表，
  不再整页换成 spinner、让所有封面重新解码。

**② 书库刷新不再重复全量封面修复**
- `repairCovers()` 会列出所有书并逐个 PDF stat 封面文件；它原本挂在每次
  书库刷新上（收藏 / 分类 / 删除 / 打开书之后都会触发）。改为只在 provider
  首次 `build()` 执行一次（变更操作不会删封面文件）。

**③ 搜索索引状态刷新**
- 从 `_Body.build()` 的 post-frame 移到 notifier 内监听书库列表：
  原实现每次书库重建都会对每本 PDF 发一次 FFI 查询。
- 状态查询改为并发 `Future.wait`；刷新中再次触发会合并成一轮追加；
  状态未变化时不发布（`mapEquals`），避免每秒轮询让所有书卡重建；
  新增 `_disposed` 守卫，防止销毁后重启轮询定时器。

**④ 请求竞态**
- 全文搜索页加入请求序号：较早的慢查询返回时不再覆盖较新的结果。
- `CharBoxCache` / `LowConfidenceCache` / `TranslatedCharBoxCache` 增加
  在途去重（选区层、低置信层、搜索命中层会同时预载同一页）与换书 / 换
  译文版本守卫：迟到的结果不再写入新书（或旧译文）的缓存。

**⑤ 内存与 IO**
- `pageTextTranslationProvider` 改为 autoDispose：翻过的页面不再把整页
  原文 + 译文常驻内存。
- AI 历史加载的消息查询由串行 N 次改为并发。
- Rust：文本翻译缓存校验直接用行内 `source_text` 比较，不再为每个块重算
  SHA-256；逐块查找改为 `HashMap`；翻译路径只读一次缓存表。分词输出改为
  单缓冲拼接（原来 `collect + join` 分配两份页级缓冲）。
- 书卡的日期正则提升为 static（原来每张卡每次 build 都重新编译）。

**验证**：`library_selection_test.dart` 新增 2 个（值相等、retain 幂等）、
`search_page_test.dart` 新增 1 个（乱序响应）、新增 `page_cache_test.dart`
（并发合并、换书不串缓存）；Flutter **310** 测试全绿、analyze 0；
Rust 139 测试通过、clippy -D warnings 0。

### 3.34 代码审计：数据正确性缺陷集中修复（2026-10-22）

一次覆盖 Dart 异步生命周期、阅读器 / 标注几何、Rust 核心三个方向的审计。
下面每条都是先核实代码路径、再修复，并尽量补了回归测试。

**① 标注会写错 / 丢数据（最高优先级）**
- **笔记弹窗串味**：`_synced` 只置位一次且从不重置。弹窗打开时点另一条标注，
  `noteTargetId` 变了但编辑器仍是上一条笔记的文本 —— 按「保存」会用旧文本
  覆盖新标注的笔记。改为按标注 id 同步。
- **撤销/重做跨书**：`_undo`/`_redo` 是普通字段，换书时不清空。在书 A 改完
  标记后切到书 B 按 Ctrl+Z，会删掉 A 的标记；撤销删除更糟 —— 闭包里 `_bookId`
  在执行时读取，会把 A 的标记重建到 B 里。改为记录历史所属书并在换书时清空。
- **译文面板的笔记落到原文层**：`NoteComposer` 调用 `create()` 时没传 `pane`，
  默认按 `original` 保存，导致笔记在创建它的译文面板里不可见、在原文页上
  位置错乱。改为与工具条一致，按选区来源传 pane。
- **图片标记缩放反向**：四个角手柄都按「中心对称缩放」计算，拖左上角时标记
  缩小且角点朝反方向跑。改为以对角为锚点，被拖动的角跟随指针。
- **浮动工具条拖不动**：拖拽只写 `toolbarPos`，而布局委托从不读它。已把该
  位置接入 `_ToolbarLayout`（含视口钳制）。
- **合并导出失败**：全分辨率渲染 + 解码后读取 `ref`，此时侧栏可能已关闭、
  `WidgetRef` 已 dispose，抛 `StateError` 且无任何提示。改为在首个 await 前
  快照标注列表。

**② 阅读器几何 / 状态机**
- **OCR 行布局错位**：`_lineLayouts` 过滤掉单字符行，但 `lineIndexAt` /
  `selectionRectsFromLines` 仍用完整 boxes 下标索引 —— 页面上只要有一个
  单字符 OCR 行（页码、孤立符号），后续所有行的选区都会错位，末尾还会
  `RangeError`。改为每个 box 都建布局，保持下标对齐。
- **搜索命中画错行**：`hitRects` 拿到的是拼接文本的字符偏移，却直接当作
  box 下标传给 `selectionRects`；OCR 页一个 box 是一整行，于是所有命中都被
  钳到最后一行。改为二分定位匹配起点/终点所在的 box（新测试覆盖跨行匹配）。
- **快速翻页丢目标**：程序化滚动动画期间的页码变化被直接 return。连点两次
  「下一页」后列表停在第 2 页而状态已是第 3 页。改为记录待跳页，动画结束后
  继续跳到最新目标（实机验证：连点两次 33 -> 35）。
- **0 页文档崩溃**：`clamp(1, 0)` 在 Dart 会抛 `ArgumentError`（下界 > 上界），
  且 `setPage` 同样问题。改为页数为 0 时跳过钳制，让阅读器显示自己的空态。
- **并发开书相互覆盖**：`openBook` 一路上没有任何请求标识，旧请求后完成会
  覆盖新书状态（书名、页数、恢复位置），而 Rust 文档是全局单例 —— 两边会
  指向不同文档。加 `_openSeq`，每个 await 后校验。

**③ 缓存串书与竞态**
- 缩略图缓存、译文字盒缓存都没有「书」的守卫：换书后迟到的渲染结果会写进
  新书的 map（同页号不同文档）。两者补 book 守卫与在途去重清理。
- 译文位图缓存在 revision 变更后只清缓存、不清在途请求，旧译文的页面会被
  写回刚清空的缓存；补 generation 校验并丢弃过期解码结果。
- AI 删除会话时无条件 `_session.cancel()`，删掉无关会话会中断正在生成的
  回答，而 `streamingThreadId` 仍保留 —— 卡片永远停在「生成中」。改为只在
  删除的正是流式所属会话时才取消。

**④ Rust 核心**
- **迁移非原子**：ALTER 与版本写入不在同一事务，升级途中被杀会留下「列已加、
  版本未记」的半迁移状态，之后每次启动都因 `duplicate column name` 永久失败。
  整条迁移链改为单事务，且每个 ALTER 前用 `has_column` 判重（新测试模拟
  半迁移并验证自愈）。
- **索引状态误判**：`has_rows` 在 `is_failed` 之前判断，构建到一半失败的书写入
  了部分行就被报告为 ready，剩余页面永远不再索引，全文搜索静默缺内容。调整
  判定顺序，并让 `ensure_book_index` 对 failed 书做「每进程一次」的重试。
- **OCR 引擎失败永缓存**：`OnceLock` 把加载失败也缓存下来，首次扫描遇到瞬时
  失败（内存压力、模型正在落盘）后，整个进程后续扫描都返回同一错误，而
  `is_available()` 仍报可用。改为只缓存成功加载，失败下次重试。
- **索引状态轮询重叠**：`Timer.periodic` 的异步回调没有重入保护，慢于 1 秒时
  会叠加批次并让旧结果覆盖新结果；同时每秒重查所有 ready 书。改为只查
  building 的书并加重入守卫。

**⑤ 启动路径**
- `_Bootstrap.coreInit` 字段此前完全未被使用：Rust 初始化失败（数据库损坏、
  目录不可写、迁移失败）后应用照常进入书库，第一次 DB 调用就在 `db()` 的
  `expect` 处 panic —— release 构建 `panic = "abort"`，整个进程被杀。现在
  初始化失败时展示可恢复的说明页，不再进入主界面。

**验证**：Flutter **318** 测试全绿（新增笔记弹窗串味、0 页文档、并发开书、
OCR 命中映射等 8 个）、analyze 0；Rust **140** 测试通过（新增半迁移自愈）、
clippy -D warnings 0。release 桌面版实机复测：启动正常、快速连点翻页
（33 -> 35 精确前进 2 页）、全文搜索跳转与页内高亮落点正确。

---

### 3.35 横屏列数与导入幂等（2026-10-22，1.8.0）

**① 横屏一行只有 4 本**
- 根因：列数按目标卡宽 184dp 四舍五入。平板横屏可用宽 889dp →
  `(889+21)/(184+21) ≈ 4.44` → 4 列 × 206dp，卡片过大。
- 修复：目标卡宽调为 **178dp**，使 889dp 落到 **5 列 × 161dp**；同时把最小
  卡宽从 152 降到 140，避免 360dp 手机因「两列卡片 148dp < 152」被判非法而
  退化成单列 318dp。
- 实测列数：手机 360→2、平板竖屏 776→3、**平板横屏 1163→5**、
  桌面 1280→5、1920→8。

**② 同一本书出现两本（导入不幂等）**
- 根因：去重只比对 `original_path`。同一份文件通过不同路径进来时不匹配：
  文件选择器报真实路径，而 ACTION_VIEW / ACTION_SEND 交给了应用缓存目录里的
  临时副本。
- 修复（schema **v10 → v11**）：
  - `books.content_hash` 存导入文件的 SHA-256（流式读取，不整文件进内存）；
  - 导入时先比路径、再比内容哈希，命中则返回已有记录（`already_existed`）；
  - 启动时 `backfill_content_hashes()` 给旧库补哈希（只处理 NULL 行）；
  - 启动时 `dedupe_books_by_content_hash()` 清理历史重复：保留**读过的那本**
    （其次最近打开、再次最早导入），合并收藏/分类，其余走正常删除路径
    （文件、封面、标注、OCR、译文缓存一并清掉）；
  - 最后建**唯一部分索引** `uq_books_content_hash`，让重复在数据库层不可能
    再发生。
- 实机验证：设备上有 8 本（「3D数学基础」重复），升级后自动收敛为 7 本，
  且保留的是读过的那一本（已读 4/767）。

**验证**：Rust **144** 测试（新增：不同路径同内容只入库一次、v10→v11 迁移加列
并建索引、启动清理保留已读副本并删除文件）；clippy 0；Flutter **322** 测试
（新增横屏 5 列 / 竖屏 3 列 / 手机 2 列 / 桌面 5 列 4 个断言）；release APK
1.8.0 构建通过、16KB 对齐通过；平板实机横屏截图确认 5 列且重复已消失。

**仍未做**：视口分块渲染、亮度手势。

### 3.36 AI 回复卡改回悬浮式并统一面板风格（2026-10-22，1.9.0）

**问题**：`ResultCard` 在手机/窄屏上走 `_dockedCard`，是一条贴底、通栏、
上圆角的 bottom sheet。选中文本后回答盖住了正文和选区，"悬浮"的语义没了。

**① 手机也悬浮**
- 删除 `_dockedCard`，两种形态合并为一条渲染路径：始终 `Positioned` 浮在
  阅读区之上，正文和选区保持可见。
- 手机尺寸不再用桌面持久化的 440×360，而是 `_effectiveSize()` 按视口钳制：
  宽 `screen.width - 24`（下限 280），高 `screen.height × 0.62`（下限 260，
  上限 `screen.height - 96`）。
- 键盘弹出时用 `viewInsets.bottom` 让上边界让位，输入行不会被挡住。
- 桌面持久化的 `cardPos`（80,120）在手机上会落到视口外：首次显示（位置仍为
  默认值时）改为**视口居中**，用户拖动后照常记住位置。
- 手机隐藏右下角 resize 手柄（卡片已被视口钳制，拖动尺寸会立刻被覆盖）。

**② 视觉对齐主界面**
- 卡面改用弹层设计系统：18dp 圆角 + `appOverlayColor` + 发丝描边 +
  `Golden.panelShadow`（原来是 8dp 圆角 + Material elevation 4）。
- 标题改**衬线加粗**（与「我的书库」「AI 结果」一致），内边距改斐波那契阶梯。
- 分隔线由 `height: 8`（视觉上是一条粗空行）改为 `height: 1` 的发丝线。
- 图标统一 20dp（原 16dp），符合项目的 16/20/24 尺寸梯度。

**验证**：新增 `result_card_phone_test.dart`（4 个：手机不贴底不通栏、
完全在视口内、水平居中、桌面保留 resize 手柄与可调尺寸）；Flutter **326**
测试全绿、analyze 0；离屏渲染确认 1080×2340 下卡片为悬浮面板形态；
release APK 1.9.0 构建通过、16KB 对齐通过。

### 3.37 悬浮卡可拖动 + 选区工具条恢复悬浮（2026-10-22，1.9.1）

**① AI 回复卡无法拖动**
- 根因一：手机分支把 `onPanUpdate` 写成了 `compact ? null : ...`，手机直接
  禁用了拖动。
- 根因二：`moveCard(delta)` 是在 `state.cardPos` 上累加，而手机首次渲染用的是
  计算出的**居中坐标**；`cardPos` 还停在桌面默认 (80,120)，第一个 delta 会
  从那个陈旧值算起，卡片会瞬移。
- 修复：拖动在所有平台启用；`onPanStart` 先把卡片**当前真实左上角**写回
  `cardPos`（新增 `setCardPosition`），再让后续 delta 做相对累加。标题栏
  加 `Key('card-drag-handle')` 便于测试与定位。

**② 选区工具条恢复悬浮**
- 之前 phone 走 `_dockedBar`：贴底、通栏、4×2 网格。用户要求恢复悬浮。
- 现在**始终悬浮**，按可用宽度选布局：
  - 手机 / 窄窗：4×2 紧凑网格（图标在上、标签在下，单元最小宽 62dp、
    高 56dp，`IntrinsicWidth` 让最宽的列决定列宽，避免「下划线」被裁）；
  - 平板 / 桌面：单行带标签按钮的 `Wrap`（800dp 分屏时自动换行）。
- 拖动：手势挂在整条工具条上，`onPanStart` 用 `GlobalKey` 读工具条真实屏幕
  坐标并 seed 到 `toolbarPos`，首个 delta 不会跳。
- 样式统一到主界面：18dp 圆角 + 面板底色 + 发丝描边 + 柔和投影
  （`Material` 承接 `InkWell` 的水波纹，视觉由 shape/border 决定）。

**③ 修过程中发现的两个真 bug**
- `CustomSingleChildLayout` 的 `getConstraintsForChild` 返回 `constraints
  .loosen()`，子级拿到**无限宽**约束，`Row` 直接撑到 79 万像素并报
  「RenderFlex overflowed by 799208 pixels」。改为 `BoxConstraints
  .loose(screen)`，并给工具条加 `IntrinsicWidth`。
- 换成 `DecoratedBox` 面板后 `InkWell` 失去 Material 祖先，运行时
  `debugCheckHasMaterial` 断言失败。改回 `Material` 承载外观。

**验证**：新增「拖动标题栏使卡片位移且仍在视口内」测试；改写手机工具条测试为
「悬浮、不通栏、8 个动作齐全」；Flutter **327** 测试全绿、analyze 0；
release APK 1.9.1 构建通过、16KB 对齐通过。

### 3.38 包名、应用名、版本号与图标定稿（2026-10-22，1.0.0）

发布前的一次标识统一：

- **包名**：`io.github.csy2569.zhiyue` → **`work.csywxk.icefish_zhiyue`**。
  同步修改 `namespace`、`applicationId` 与 4 个 Kotlin 源文件的 `package`，
  目录随之迁移到 `android/app/src/main/kotlin/work/csywxk/icefish_zhiyue/`。
  新包名与作者已有的 `work.csywxk.icefish_note` 同属一个命名空间。
- **应用名**：Android 的 `android:label` 原本已是「智阅」，无需改动
  （`flutter build` 会把它写进 `application-label`）。
- **版本号**：重置为 **1.0.0 (versionCode 1)**，作为首个正式发布版本。
- **图标**：换成新版方形图标（文档 + AI 星芒 + 对话气泡）。生成三套：
  - legacy `mipmap-*/ic_launcher.png`（48/72/96/144/192），
  - adaptive `mipmap-anydpi-v26/ic_launcher.xml` + 前景层
    `ic_launcher_foreground.png`（108/162/216/324/432，内容占 66% 安全区），
  - 背景色 `@color/ic_launcher_background` = `#FDFDFF`（取自图标自带底板），
    并带 Android 13+ 的 `<monochrome>` 主题图标声明。
  同时把 `assets/ZhiYue.png` 与 `packaging/icon/zhiyue.png` 更新为同一张
  512px 版本，Linux 打包使用同一素材。

**验证**：`aapt2 dump badging` 确认 `package=work.csywxk.icefish_zhiyue`、
`versionName=1.0.0 versionCode=1`、`application-label='智阅'`、
`application-icon-*` 指向 adaptive XML；Flutter 327 测试全绿、analyze 0；
真机安装（`pm install`）并截图确认图标在桌面与 Dock 显示正常、遮罩裁切无溢出；
release APK 269MB、16KB 对齐通过。

**注意**：包名变更意味着这是**新应用**，无法覆盖安装旧版本（`io.github.csy2569.zhiyue`），
旧应用的数据也不会自动迁移。设备上已手动卸载旧包。

### 3.39 桌面端反馈修复：单行工具条、双页对齐、拖动、主题、书架筛选与批注内联（2026-10-22，1.9.2）

桌面端一轮使用反馈的 8 项改进，逐条定位根因后修复：

**① 悬浮选区工具条被折成两行**
- 根因：桌面走 `Wrap`，而 `Wrap` 的 max intrinsic width **不计 `spacing`**，
  `IntrinsicWidth` 给出的宽度比真实单行宽度少 2dp，最后一个「笔记」被挤到
  第二行。
- 修复：桌面改回 `Row`（最小主轴尺寸），8 个动作严格单行；窄窗仍走手机
  4×2 网格。

**② 双页翻阅 / 双页滚动错位**
- 根因一（最明显）：浅色主题用 `ColorFiltered(multiply)` 包每一页。并排两页
  时，前一页的 `ColorFilterLayer` 只画出纯色滤镜层、内容丢失，左页整片空白，
  看起来像"整块内容错位到右边"。改为把纸色乘到 `RawImage.color` +
  `BlendMode.multiply`（无额外 `saveLayer`），两页都正确着色。
- 根因二：翻页动画把「页高 + 间距」当作页高传给 `_offsetForPage`，后者又加
  一次间距，每翻一页多走 16dp，连续翻页后偏移累积。
- 根因三：占位页没有宽度（`SizedBox(height:)`），双页行只剩 gutter 宽，位图
  到达后行宽骤增又被重新居中，双滚/双翻看到横向跳动。新增
  `pageWidthProvider`，占位按真实页宽渲染，并用 `SizeChangedLayoutNotifier`
  在内容尺寸变化后重新居中。

**③ AI 悬浮卡拖动瞬移、标题栏与指针错位**
- 根因一：新动作把 `cardPos` 重置为桌面默认 (80,120)，但 `_beginDrag` 无论
  平台都把「居中坐标」写回；桌面卡片实际画在 `cardPos`，于是第一次拖动从
  另一处起算，卡片瞬移。
- 根因二：拖动过程不做边界限制，越界坐标持续累加；build 里再 clamp，卡片
  贴在边上不动而指针继续走，标题栏离开鼠标。
- 修复：`_beginDrag` 写入「实际绘制位置」；拖动每步 clamp 到视口。选区工具
  条同样处理。

**④ 主题切换只在「跟随亮度」下有效**
- 根因：书库右上角按钮改的是遗留的 `ThemeMode`，而 `resolveReadingTheme`
  在用户选了具体主题时直接返回该主题、完全忽略 `ThemeMode`。
- 修复：按钮改为切换**阅读主题**本身（亮 ↔ 暗，`toggledReadingTheme`），与
  设置页同一份持久化。

**⑤ 书架顶部选择栏"点一个亮两个"**
- 根因：旧实现给每一项各挂一个 `AnimatedContainer` 背景，160ms 过渡期间
  旧项淡出、新项淡入，两项同时着色。
- 修复：改为**单一滑动指示器**（`AnimatedPositioned`），任何时刻只有一个高亮。

**⑥ 顶部选择栏与左侧栏重复**
- 顶部栏改为**文件类型**轴（全部格式 / PDF / 图片），左侧栏只保留**视图**轴
  （所有文档 / 最近使用 / 我的收藏 / 文件夹）。两者正交，可组合（如「我的
  收藏 + PDF」），不再有同名项，也不会互相点亮。
- `LibraryView` 去掉 `pdf` / `image`，新增 `LibraryType`；`filteredBooksProvider`
  同时应用两条轴。

**⑦ 设置入口重复**
- 删除左侧栏的「设置」项，仅保留书库右上角入口（路由仍支持 `/settings`）。

**⑧ 批注二级浮条**
- 原「批注」按钮会在页面上方弹出第二条浮动工具条。现在批注工具（选择 / 画笔 /
  形状 / 便签 / 图章 / 撤销重做 / 调色 / 线宽 / 退出）直接渲染在阅读顶栏
  **中间段**，未启用批注时中间段仍是视图模式 / 缩放 / 翻页。

**验证**：新增 `desktop_feedback_regression_test.dart`（6 个）与拖动 clamp
回归测试；Flutter **323** 测试全绿、analyze 0；`flutter build linux --release`
通过；离屏渲染确认双翻/双滚两页都着色、桌面选区工具条单行、批注内联、书架
顶部只剩类型筛选。

**移动端对应改动**（3.40）：选区工具条的手机形态改为单行纯图标，手机
顶栏内联批注工具。共享部分（单行 `Row`、`MarkToolOptions` 的 `compact` /
`showExit` 参数）已落在本分支并同步到 `android`。

## 4. 后续开发方向

### 4.1 近期（补齐规格 P2 缺口）

| 优先级 | 需求 | 说明 |
|---|---|---|
| P2 | ~~**7.1.6 置信度展示**~~ | ✅ 已实现（2026-08-10）：低置信度行页面标记 + 计数提示 |
| P2 | ~~**7.1.7 识别结果手动修正**~~ | ✅ 已实现（2026-08-10）：点击标记行编辑文本，回存 + 重入搜索索引 |
| P1 | **7.3 图片阅读器全流程** | 图片书已可打开阅读，补缩放 / OCR / 标记全流程一致性验证 |
| P2 | **双页模式缝隙衔接** | 双页模式下跨页选区、标注的边界行为打磨 |
| — | **拖拽归类完成度** | 分类管理已实现，验证拖拽交互与批量归类的完整路径 |

### 4.2 中期（体验与性能优化）

- **启动优化**：目标 <1s（当前启动加载 FRB + SQLite + 模型探测）
- **安装体积优化**：LTO、strip、按需模型下载（当前模型占 ~210MB 存储）
- **OCR 排队与取消**：多页扫描任务队列、可取消（rapidocr 支持取消令牌）
- **AI 对话体验**：上下文管理（滑动窗口 / 手动清空）、回答流式渲染优化
- **导出增强**：标注拼合 PDF、导出格式扩展（HTML/EPUB）

### 4.3 远期（新能力）

- **划词 AI 快捷操作**：选中即弹翻译 / 解释 / 搜索（当前需手动触发）
- **阅读进度统计与书摘**：阅读时长、笔记汇总导出
- **PDF 目录 / 书签编辑**：侧栏目录当前为只读展示
- **多书对比阅读** / **双开模式**
- **模型管理界面**：OCR 模型版本检查、在线更新

### 4.4 工程债与维护

- FRB 死字段清理（`FormulaRegion.image_path/placeholder`、`ParagraphKind::Noise` 等已无生产写入，删除需一次 codegen + Dart 再生成）
- FRB 生成代码勿手改（统一 codegen 后提交）
- 持续补充 Rust 单测覆盖（db/repository、pdf 模块）
- 性能回归基准（OCR 页级耗时、搜索延迟）固化到文档

## 5. 风险与注意事项

- **rapidocr-core 较年轻**：已锁定版本；备选自研 ort 管线（PP-OCRv4 流程已明确）
- **精准优先 vs 占用**：高精度模型 +300MB 内存是规格内取舍，懒加载 + 双模式缓解
- **单人里程碑制**：每里程碑按 FEATURES.md 条目验收，先提交后优化
