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
| M7 对照阅读（双语阅读） | 阅读页「对照阅读」按钮 + 译文窗格（像素宽度可拖拽、双页同显、空态引导、整本进度）/ 段落级抽取（基线聚行+断字还原+噪声剔除+字体元数据公式识别，全程独立 pdfium 句柄）/ DeepL + OpenAI 兼容翻译（严格对齐、占位符防伪造与回填校验、限流退避、术语表）/ 三种翻译方式（整本 / 随进度 / 手动）+ Dart 队列编排与续传 / 术语表与固定保留设置 / 按需导出译文 PDF（1..N 顺序、占位页、p.N 锚点、原页尺寸、可选中文本、公式小图、运行时字体子集化）/ 2GB LRU + 删书级联 | ✅ 完成（2026-09-11） |

## 3. 当前技术状态（关键数据）

| 指标 | 实测 |
|---|---|
| 整页 OCR 性能（release，A4 合成页） | 快速 ~0.4s/页，高精度 ~1.8s/页（目标 ≤0.5s / ≤3s） |
| 空闲内存（release，未扫描时） | RSS ~294MB（OCR 引擎懒加载，扫描时按模式 +35~300MB） |
| 存储占用 | ~790MB（文档 570 + 模型 210 + DB ~9.5MB 含搜索索引 2.9MB） |
| 全文检索性能 | FTS5 查询 <10ms，命中高亮 <1ms/帧（缓存复用） |
| 测试规模 | Rust 单测 117 个 + OCR e2e 6 个（真实模型，`--ignored`）+ Flutter widget 测试 192 个，全部通过 |
| 静态检查 | clippy 零新增警告；flutter analyze 零问题 |

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

- `rust/examples/` 与部分调试脚本清理
- FRB 生成代码勿手改（统一 codegen 后提交）
- 持续补充 Rust 单测覆盖（db/repository、pdf 模块）
- 性能回归基准（OCR 页级耗时、搜索延迟）固化到文档

## 5. 风险与注意事项

- **rapidocr-core 较年轻**：已锁定版本；备选自研 ort 管线（PP-OCRv4 流程已明确）
- **精准优先 vs 占用**：高精度模型 +300MB 内存是规格内取舍，懒加载 + 双模式缓解
- **单人里程碑制**：每里程碑按 FEATURES.md 条目验收，先提交后优化
