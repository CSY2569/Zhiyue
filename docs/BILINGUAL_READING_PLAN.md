# 对照阅读（双语阅读）方案 v4.2

> **历史文档（v4.2，自研管线时代）**：本方案描述的自研翻译管线已于 2026-09-18 移除，
> 引擎先后由 BabelDOC 与 RetainPDF 管线承担。当前实现见
> `docs/IMPLEMENTATION_STATUS.md` §3.16–§3.18 与 `docs/FEATURES.md` §7.4；
> 下文仅作设计史参考，术语与组件名均已变化。

> 状态：**已实施完毕**（2026-09-14；后续演进与决策记录见 [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) §3.7–3.14，工作流程整理见 [bilingual_workflow.html](bilingual_workflow.html)）。
> 本文档为定稿时的原始方案；其中「右栏像素宽度可拖拽」「公式小图」等设计已被后续
> 改版取代（左右 50/50 分栏、公式保留原像素），保留作为决策历史。
> 日期：2026-09-11（v4.2 审核定稿）。
>
> v4.2 变更（相对 v4.1，来源：代码库审核 + 用户决策）：
>
> 1. **P0** 启用 pdfium-render `paragraph` feature —— `PdfParagraph` 模块被 `#[cfg(feature = "paragraph")]` 门控（pdfium-render 0.9.3 `src/pdf/document/page.rs:17`），项目 Cargo.toml 现仅启用 `image_latest, thread_safe`，不开启则 §3 首选路径编译失败。
> 2. **P0** 翻译侧全部操作改用**独立文档句柄**（按 `stored_path` 临时打开），不触碰阅读器的全局单文档锁（`rust/src/pdf/pdfium.rs:20 static DOC`），保证整本抽取/公式截取与翻页渲染互不阻塞。
> 3. **P0 + 用户决策** 整本翻译后台行为改为**用户可选**：首次触发整本翻译时弹选择框，选择记入设置；可选「后台继续 / 切书暂停·回来续传 / 离开即取消」。补全任务生命周期（确认框、退出停止、重开自动续传）。
> 4. **P0** 补**双页模式**（double_scroll / double_page，`viewer_provider.dart:140-148` 步进 2）语义：本页 = 两个可见页；右栏同显两页译文。
> 5. **用户决策** 译文 PDF 改为**按需生成**：点「导出 PDF」时按 1..N 一次性构建；删除 v4.1 的「任一页完成触发防抖增量重建」。
> 6. **用户决策** 翻译目标语言**统一为一处**：沿用 AI 设置现有「翻译目标语言」（`AiConfig.translateTargetLang`，`settings_page.dart:660` ChoiceChip），划词翻译与对照阅读共用；`TranslationConfig` 不再单独设目标语言。
> 7. **P1** 译文面板宽度改**像素模式**（沿用 `PanelLayout` KV + clamp 惯例，`panel_layout.dart:71-84`），并定义与左侧栏 / AI 面板同开时的正文最小宽度。
> 8. **P1** LRU 补数据结构（`last_accessed_at` / pinned 固定保留 / 不可逐出规则 / 检查时机）；删书级联补 `page_translation_cache` 行清理。
> 9. **P1** 字体首步验证补**轮廓格式**（官方发行多为 OTF/CFF，pdfium 按 TrueType 加载，CFF 可用性不保证）与**字体分发方式**。
> 10. **P2** 其余：注入防御沿用 `wrap_input`、占位符防伪造、DeepL 配额/glossary/语言码细节、右栏空态引导、整本进度展示位置、翻译方式默认值 = 随进度、译文 PDF 页面尺寸取原书尺寸、明确「物理页码 ≠ 原书页码」、FRB 类型置于 `rust/src/models/`、阶段 2/5 补单测、OCR 行→段落合并、已知限制补多栏回退。

## 0. 需求背景

阅读外语文献时开启对照阅读：阅读页左上方功能区新增「对照阅读」按钮，开启后在正文旁生成译文窗格，将当前页文本翻译为用户设定的目标语言；**不改变原文格式、公式、图片等内容，只翻译文本**。翻译方式（整本自动 / 随进度 / 手动）由用户在设置中选择。

## 1. 交互与布局

- `lib/features/reader/widgets/reader_toolbar.dart`：左侧功能区（缩略图/目录/标注之后）新增 `ToolbarIconButton(icon: Icons.translate, tooltip: '对照阅读')`，开关状态模式照抄 AI 面板按钮（`reader_toolbar.dart:141-146`）。
- `lib/features/reader/reader_page.dart` 的 Row：开启后在原文 `Expanded` 之后、AI 面板之前插入 `PanelResizeHandle` + `TranslatedPane`。左栏原页渲染路径完全不变。
- **面板宽度（v4.2 修订）**：沿用 `PanelLayout` 现有**像素宽度 + clamp** 模式（不用比例）：
  - `PanelLayout` 新增 `translatedPaneWidth` 字段，默认 480，clamp 范围 280–900（逻辑像素）；
  - KV 键 `panel_width_translated`，拖拽结束 `commit()` 持久化，照抄 `aiPanelWidth`（`panel_layout.dart:73-74, 93`）。
- **同开时的最小宽度（v4.2 新增）**：正文区（`PdfPageScroll`）保留最小 360px。左侧栏（≤480）+ 译文栏（≥280）+ AI 面板（≥240）叠加挤压正文时，按「后开启者优先」将先开启的面板宽度 clamp 到剩余空间；仍不足则自动收起左侧栏（仅提示一次）。
- **双页模式（v4.2 新增）**：double_scroll / double_page 下按钮与窗格行为一致；「本页」= 当前后两个可见页，右栏同时显示两页译文（见 §5）。

## 2. 阅读顺序与页码一一对应（硬约束）

- 缓存键含**绝对页码**：`page_translation_cache(book_id, page, target_lang, provider, source_hash)`；完成顺序与跳读路径不影响任何页归属。
- 组装译文 PDF **永远按页码 1..N 遍历缓存**，不按完成时间追加；跳跃阅读后顺序仍严格等于原书。
- 未译页插入占位页（“原书第 N 页 —— 尚未翻译”），部分翻译不导致页码前移。
- 每页译文以“原书 p.N”标记开头，作为原文↔译文定位锚点。
- **物理页码 ≠ 原书页码（v4.2 明确表述）**：译文允许自然跨页（中文与外文篇幅不同），导出 PDF 的物理页数可与原书不同；定位一律靠 p.N 锚点。实现不得为凑一页对一页而缩小字号或截断译文。
- 右侧窗格**只绑定当前可见页**（单页 = `currentPage`；双页 = 两个可见页）查缓存，不显示过期内容。
- ~~任一页完成触发防抖增量重建~~（v4.2 删除：译文 PDF 改为按需生成，见 §7）。

## 3. Rust 段落抽取 —— 新模块 `rust/src/translate/`

0. **前置（v4.2 新增）**：
   - `rust/Cargo.toml` 的 `pdfium-render` features 增加 `"paragraph"`（零依赖成本）。
   - **独立文档句柄**：段落抽取、公式小图截取等所有翻译侧 PDF 操作，一律按 `stored_path` 临时 `PdfDocument::load_from_file(...)` 打开（照抄 `extract_document_text` / `render_thumbnail_file` 的独立文档模式，`pdfium.rs:268/287`），**绝不使用阅读器全局 `DOC` 锁**，避免与 `render_page` 串行争锁导致翻页卡顿。
   > **实施修正（2026-09-11，重要）**：pdfium 的 C 库**不是线程安全的**，`thread_safe` feature 只让包装类型 `Send+Sync`。并发（默认并发数 3）调用时文本抽取会**静默返回 0 段落**、渲染报 `PdfiumLibraryInternalError`，并发首绑定还会 SIGTRAP 崩溃 —— 结果是每页走「空页」分支、**完全不发翻译请求**。因此实际实现改为：新增进程级 `PDFIUM_LOCK`，**所有** pdfium 入口（含独立句柄路径）统一串行化（`with_document_file` / `with_pdfium_lock`）。"独立句柄"的意义从"绕过锁"变为"不污染阅读器的打开文档"，并发安全由 `PDFIUM_LOCK` 保证。
1. **段落重建**：优先 `PdfParagraph::from_objects()`（pdfium 原生阅读顺序）+ `text_separated()` 拼接（解决空格）；非文本版式回退基线聚行/分栏。
   > **实施记录（2026-09-11）**：pdfium-render 0.9.3/0.9.4 虽可编译 `paragraph` feature，但 `PdfParagraph` 未被 crate 公开导出（`pdf` 模块私有、prelude 不含该类型，源码注释称 "Temporary until PdfParagraph is included in the prelude"）。因此**采用本节既定的基线聚行/分栏回退路径作为主实现**（`rust/src/translate/extract.rs`），已覆盖断字还原、连字归一化、噪声剔除与公式区域识别；`paragraph` feature 仍保持启用以便上游导出后切换。
2. **断字还原**：`PdfPageTextChar::is_hyphen()` + 行尾小写规则；连字归一化。
3. **噪声剔除**：位置 + 跨页重复度识别页眉/页脚/页码。
4. **公式识别（基于文档自带元数据）**：`font_name()` 命中数学字体族（CM*/MT*/Symbol/STIX/XITS/Cambria Math）、`font_is_symbolic()`、`scaled_font_size() ≠ unscaled_font_size()`（上下标）、`angle_degrees()`。命中片段从原页对应区域截取小图（同样走独立句柄渲染）。
   > **实施修正（2026-09-11）**：宽泛的 `CM*` / `MT*` 前缀会误伤 LaTeX 正文（正文即 Computer Modern / TeX Gyre），导致整篇被判为公式、右栏无译文。改为：只匹配数学**专用**字体族，并新增**内容闸门** `text_looks_like_formula`（含普通单词则绝不判为公式；公式须含运算符/关系符/希腊字母）。字体元数据不再单独构成判据。
5. **扫描页**：无文字层且开启自动 OCR 时走 `scan_page`（带缓存）；`confidence < 0.8` 标“低置信，请核对”。**OCR 行→段落合并（v4.2 新增）**：`OcrLine` 为行级结果，按行距/缩进并入 §3.1 的段落重建流程，输出统一的 `Paragraph`。
- 输出 `Paragraph { text, rects[], page, kind, confidence, formula_regions[] }`；**跨 FFI 类型定义于 `rust/src/models/`（v4.2 明确，架构要求）**。
- 以上 pdfium-render API 均已对照 0.9.3 源码逐项核实存在（见附录 A）。

## 4. 翻译层 —— `rust/src/translate/providers.rs`

1. **段落级**翻译（非行框级）。
2. **严格对齐**：LLM 要求 JSON 数组 `[{i,t}]` 并校验 index；缺项/错位逐段重译；DeepL 批量天然对齐。
3. **占位保护 + 回填校验**：公式片段占位符（DeepL `ignore_tags`；LLM `⟨MATH_n⟩`），译后回填原始子串，断言每个占位符恰好出现一次且未变，失败标“公式需核对”或重译。**防伪造（v4.2 新增）**：原文中出现形如 `⟨MATH_n⟩` 的字符串时先转义/替换；占位符 token 加随机前缀。
4. **上下文与术语表**：携带书名与相邻段落；`translation_glossary` 表 + 设置界面（DeepL glossaries / LLM prompt 注入），全书译名一致。**DeepL glossary 细节（v4.2 新增）**：需先经 API 创建 glossary 资源并持久化 `glossary_id`，且语言对必须与请求的源/目标语言匹配。
5. **源语言判定**：“中英互译”按段落 CJK 占比判定。
6. **适配器**：`DeepLProvider`、`OpenAiCompatibleProvider`（通用自定义，可复用 AI 配置）；限流 + 429/5xx 退避重试。
7. **完整性校验**：每段（公式/剔除段除外）必须有非空译文，产出页级覆盖率；失败段显式标注。
8. **注入防御（v4.2 新增）**：沿用现有 `wrap_input` `<text>` 包装模式（`api.rs:1260`）——书籍内容是不可信输入，段落文本送入翻译提示词前同样包裹。

## 5. 右侧译文窗格 —— `lib/features/bilingual/widgets/translated_pane.dart`

- `SelectionArea` + 逐段 `Text`：可选中、应用内可检索、可复制。
- 段落状态：待翻译/翻译中/完成/低置信/失败（可重试）/公式需核对；顶部显示“原书 p.N”与覆盖率。
- 逐段“本段用原文”切换；公式区域显示对应小图或原文。
- 与阅读进度同步，跳页立即定位。
- **双页模式（v4.2 新增）**：同屏显示两个可见页的译文（上下分区），各带 p.N 锚点。
- **空态引导（v4.2 新增）**：未配置翻译服务（未选服务/未填 Key）时显示“未配置翻译服务”卡片 +「去设置」按钮，不空转报错。
- **整本进度（v4.2 新增）**：整本模式进行中，窗格头部显示「已完成 x/N 页 · 预计剩余 ~mm 分钟」+「取消」按钮。
- **目标语言（v4.2 修订）**：窗格头部显示当前目标语言，取自 `AiConfig.translateTargetLang`（与划词翻译一致），本功能设置区不再单独配置。

## 6. 译文 PDF（正文可选中，公式用小图）—— `rust/src/translate/pdf_writer.rs`

- **按需生成（v4.2 修订，用户决策）**：不再随翻译完成增量重建。右栏头部提供「导出 PDF」入口，点击时按 §2 全部规则（1..N 遍历、占位页、p.N 锚点）一次性构建，构建中显示进度。
- 正文：`create_text_object` + `set_text` 写入真实文本（可选中/可检索），用 `PdfFont::glyphs()` 量宽自算断行。
- 公式：从原页区域截取 PNG，`create_image_object` 嵌入（`image_api` 已随 `image_latest` 启用），视觉 100% 保真。
- **页面尺寸（v4.2 新增）**：译文 PDF 每页取原书对应页尺寸，保持版式观感。
- 每页“原书 p.N”；未译页占位页；按 1..N 排序。
- 中文字体：**Noto Sans CJK SC / 思源黑体（Source Han Sans SC），SIL OFL 1.1**（允许嵌入/打包/商用/子集化）。**优先选 TTF 轮廓变体（v4.2 新增）**：官方发行多为 OTF/CFF 轮廓，pdfium `FPDFText_LoadFont` 按 TrueType 加载，CFF 可用性不保证。`load_true_type_from_file(..., is_cid_font=true)`；随包只内置 Regular（必要时 Bold）；确认 Reserved Font Name 声明，如有则给子集产物改名并单独附 OFL 许可文件，不并入 GPL 代码。
- **首步验证（实施 §11 阶段 5 的第一步执行，v4.2 扩充为三项）**：
  1. 所选字体文件能否被 `load_true_type_from_file` 加载（TTF 轮廓验证）；
  2. `FPDF_SaveAsCopy` 保存是否子集化嵌入字体（否则整字体内嵌会让每个 PDF 膨胀约 10MB）；
  3. Reserved Font Name 声明确认。
  任一受阻：换 TTF 轮廓变体 / 换 Noto Sans SC / 回退 `printpdf`、`lopdf`。
- **字体分发（v4.2 新增）**：二选一——a) `include_bytes!` 编入 Rust crate（`.so` 增大约 8–10MB，路径最简单，**建议**）；b) 随包文件 + 运行时路径（保持 `.so` 体积，需打包脚本配合）。实施时定案写入本节。
  > **实施定案（2026-09-11）**：采用 a) `include_bytes!`。字体为 Noto Sans SC Regular（SIL OFL 1.1，TTF/glyf 轮廓，随包附 `rust/assets/fonts/OFL.txt`；上游名称为「Noto Sans SC」，无 Reserved Font Name 冲突）。**首步验证结论**：pdfium 的 `FPDF_SaveAsCopy` **不子集化**嵌入字体（10MB 字体会让每个 PDF 膨胀约 6MB），且 `subsetter` 会丢弃 cmap、无法供给 pdfium 的字符串文本 API —— 故按 §6 回退链**改用 `lopdf` 手写 PDF**（`rust/src/translate/pdf_writer.rs`），构建期用 `subsetter` 把字体子集到全书实际用到的字形，并生成 `/ToUnicode` CMap 保证文本可选中/可检索。实测 3 页含中文译文与占位页的 PDF < 1MB。
- 输出 `translated/{book_id}/{lang}.pdf` + 公式小图目录；构建产物计入 §7 缓存上限。

## 7. 性能与缓存

**性能（v4.1 核实数据，供参考）**：段落抽取+重建 10–50 ms/页；扫描页 OCR 约 0.4 s（快速）/ 1.8 s（高精度）（仓库实测）；翻译 DeepL 约 1–2 s/页、LLM 约 3–10 s/页；右栏渲染低于一帧。整本 300 页：文字版 DeepL 约 5–10 分钟、LLM 约 20–50 分钟；扫描版另加 OCR 约 2–9 分钟。空闲内存增量为零。

**存储（2GB 上限）**：文字为主约 6–8 MB/本（约 260–330 本）；普通教材约 10–13 MB/本（约 160–200 本）；公式密集约 25–35 MB/本（约 60–80 本）。

**缓存策略（v4.2 补全数据结构）**：
- `page_translation_cache` 增加 `last_accessed_at` 列，右栏取数时刷新该书最新访问时间。
- **固定保留（pinned）**：KV `translation_pinned_books` 存书 id 列表，设置区 / 书库管理。
- **逐出规则**：2GB 上限 + 最久未访问优先释放（LRU）；**正在翻译或当前打开的书不可逐出**；先删未 pinned 书的 `translated/{book_id}` 产物（译文 PDF 与公式小图），保留体积很小的段落缓存行，以便即时重建与续传。
- **检查时机**：导出构建完成后 + 应用启动时；后台静默执行。

**删书级联（v4.2 补全）**：`delete_book`（`api.rs:354`）除清理 `translated/{book_id}` 目录外，**同时删除 `page_translation_cache` 中该书全部行**（建表时 FK `ON DELETE CASCADE`，或在 `delete_book` 显式清理）；该书任务进行中则先取消。

## 8. 设置 —— `lib/features/settings/settings_page.dart`

新增「对照阅读」区，独立 `TranslationConfigNotifier`（KV 键 `translation_config`）：
- 翻译服务：DeepL / 通用自定义（OpenAI 兼容）/ 复用 AI 配置；各自 URL、Key、模型。
- **目标语言：不在本区设置（v4.2 修订，用户决策）**——统一使用 AI 设置现有「翻译目标语言」（`AiConfig.translateTargetLang`，`settings_page.dart:660` ChoiceChip），划词翻译与对照阅读共用一处。
- 源语言（自动/指定）。
- **翻译方式（默认：随进度，v4.2 补默认值）**：整本书自动 / 随进度翻译本页+后两页 / 手动（仅点“翻译本页”）。
- **整本翻译后台行为（v4.2 新增，用户决策）**：后台继续（切书/关面板不取消）/ 切书暂停·回来续传 / 离开即取消。**首次触发整本翻译时弹选择框选定并记入本设置**，此后可在此修改。
- 扫描版自动 OCR（默认开）、并发数、术语表编辑、缓存上限（默认 2GB）、固定保留管理。
- DeepL 语言代码映射（界面显示名 ↔ `ZH`/`EN`/… 代码）。
- 文案沿用现有硬编码中文（项目无 i18n）。

## 9. 数据与迁移

- 新表 `page_translation_cache`（键见 §2，含 `last_accessed_at`，对 `book_id` `ON DELETE CASCADE`）+ `translation_glossary`。
- `SCHEMA_VERSION` 6→7，改 `rust/src/db/schema.rs` 与 `rust/src/db/connection.rs` 迁移链（当前仓库为 6）。
- 跨 FFI 类型（`TranslationConfig` / `Paragraph` / `TranslationStatus` / `TranslationOverview` 等）定义于 `rust/src/models/`。
- 新 FRB API（v4.2 补队列编排与按需构建）：
  - `extract_page_paragraphs(book_id, page)`
  - `translate_page(book_id, page)`（流式进度）
  - `get_page_translation(book_id, page)`
  - `get_translation_overview(book_id)`（整本进度 / 续传判断）
  - `start_book_translation(book_id)` / `cancel_translation(book_id)`（整本入队 / 取消）
  - `build_translated_pdf(book_id, lang)`（按需构建，流式进度）
  - `clear_translations(book_id)`
  - `get/set_translation_config`
  - 执行 `flutter_rust_bridge_codegen generate`。
- **编排模型（v4.2 明确）**：整本队列在 Dart 侧（Riverpod notifier，并发数取设置值，逐页调用上述原子 API）；应用退出任务自然停止；重新打开该书时经 `get_translation_overview` 判断“任务未完成且模式允许（后台继续 / 暂停续传）”则自动续传，缓存跳过已完成页。

## 10. 三种翻译方式的行为

- **整本书**：开启前弹**确认框（v4.2 新增）**——页数、字符量估算、预计时长、DeepL 配额（free 档 500k 字/月）或 LLM token 成本估算；确认后全书入队，并发逐页抽取+翻译+缓存；进度显示在右栏头部（§5）、可取消；切书/关闭面板的行为按「整本翻译后台行为」设置执行（首次触发时弹选择框）。
- **本页+后两页**：每次翻页自动入队当前页及后两页（双页模式 = 两个可见页 + 其后两页），已完成跳过。
- **手动**：仅点右栏内“翻译本页”按钮（双页模式翻译两个可见页）。

## 11. 分阶段

1. Rust：Cargo features（`paragraph`）+ 配置模型 + 表迁移 + 段落抽取（独立句柄 + 原生段落 API + 字体元数据公式识别 + OCR 行合并）+ FRB + 单测。
2. Rust：翻译适配器（DeepL/通用）+ 严格对齐 / 占位符回填校验 / 注入防御 / 术语表。**单测（v4.2 新增）**：index 对齐、占位符回填恰好一次。
3. Flutter：工具栏按钮 + 分栏（像素宽度 / 同开最小宽度约束）+ 手动单页闭环（窗格绑定页码、双页、空态引导）。
4. 设置（含「整本翻译后台行为」项与首次弹窗）+ 三种模式 + Dart 队列编排 / 续传 / 取消 + 整本确认框 + 扫描版 OCR。
5. 译文 PDF：**按需构建**（正文文本 + 公式小图 + 原书页面尺寸 + 页码标记 + 占位页 + 1..N 排序）+ 字体三项首步验证与分发定案。**单测（v4.2 新增）**：1..N 组装排序、占位页插入。
6. 2GB LRU（含 pinned / 逐出规则）+ 导出 + 测试与文档（更新 `docs/FEATURES.md`、`docs/IMPLEMENTATION_STATUS.md`）。

## 12. 已知限制

- **正文同字体的行内数学无法本地可靠区分（v4.2）**：靠严格提示词 + 回填校验 + 逐段“公式需核对/用原文”兜底；原页不动，最坏只是右栏译错而非损坏。**实施补充（2026-09-11）**：已加内容闸门防止**反向**误判（把整篇正文误当公式而完全不翻译）；行内公式的漏检（当作普通文本送去翻译）仍由回填校验与逐段“用原文”兜底。
- OCR 低置信段会被标注而非静默翻译。
- **多栏 / 非文本版式的回退（基线聚行/分栏启发式）质量有限（v4.2 新增）**：极端版式可能段落切分错误，右栏可逐段“用原文”兜底，原页不受影响。
- **物理页码 ≠ 原书页码（v4.2 明确）**：译文自然跨页时导出 PDF 的物理页数与原书不同，定位靠 p.N 锚点。
- Reserved Font Name 声明需实现时确认（不影响使用，必要时给子集产物改名）。

---

## 附录 A：pdfium-render 0.9.3 API 核验记录（2026-09-11，本机 crate 源码逐项核对）

| 方案引用 | 核验结果 | 源码位置（crate 内） |
|---|---|---|
| `PdfParagraph::from_objects()` | ✓ 存在，**需启用 `paragraph` feature** | `src/pdf/document/page/paragraph.rs:273`（门控：`src/pdf/document/page.rs:17`） |
| `PdfParagraph::text_separated()` | ✓ | `src/pdf/document/page/paragraph.rs:821` |
| `PdfPageTextChar::is_hyphen()` | ✓ | `src/pdf/document/page/text/char.rs:683` |
| `PdfPageTextChar::font_name()` | ✓ | `src/pdf/document/page/text/char.rs:209` |
| `PdfPageTextChar::font_is_symbolic()` | ✓ | `src/pdf/document/page/text/char.rs:274` |
| `PdfPageTextChar::scaled/unscaled_font_size()` | ✓ | `src/pdf/document/page/text/char.rs:131,142` |
| `PdfPageTextChar::angle_degrees()` | ✓ | `src/pdf/document/page/text/char.rs:488` |
| `create_text_object` | ✓（`PdfPageObjectsCommon` trait 方法） | `src/pdf/document/page/objects/common.rs:141` |
| `set_text` | ✓ | `src/pdf/document/page/object/text.rs:406` |
| `PdfFont::glyphs()` | ✓ | `src/pdf/font.rs:619` |
| `create_image_object` | ✓（`image_api` feature，已随 `image_latest` 启用） | `src/pdf/document/page/objects/common.rs:336` |
| `Pdfium::create_new_pdf()` | ✓ | `src/pdfium.rs:461` |
| `PdfDocument::save_to_bytes()` | ✓（`FPDF_SaveAsCopy`） | `src/pdf/document.rs:385` |
| `load_true_type_from_file(path, is_cid_font)` | ✓（文档明确支持亚洲字符集 CID 字体） | `src/pdf/document/fonts.rs:417` |

运行期仍需验证（无法静态核实）：字体子集化保存行为、OTF/CFF 加载（§6 首步验证）。

## 附录 B：代码库锚点（实施时定位）

- 阅读页布局与 Row 挂载点：`lib/features/reader/reader_page.dart:186-268`（AI 面板挂载 :211-225）
- 工具栏与按钮模式：`lib/features/reader/widgets/reader_toolbar.dart`（左组 :43-60，AI 面板按钮 :141-146）
- 面板宽度持久化：`lib/features/reader/providers/panel_layout.dart`（clamp :71-84，KV 键 :90-94）
- 页码/翻页状态：`lib/features/reader/providers/viewer_provider.dart`（双页步进 :140-148）
- 全局单文档锁与独立文档先例：`rust/src/pdf/pdfium.rs:20`（锁）、`:268`（render_thumbnail_file）、`:287`（extract_document_text）
- 文本提取：`rust/src/api.rs:789`（extract_text / CharBox）；OCR：`rust/src/api.rs:1548`（scan_page）
- 现有翻译链路：`rust/src/ai/prompts.rs:11`（translate_system）、`api.rs:1260`（wrap_input）、`lib/features/annotation/widgets/floating_toolbar.dart:65-70`
- 目标语言现有设置：`lib/features/settings/settings_page.dart:660`（AiConfig.translateTargetLang）
- Schema：`rust/src/db/schema.rs`（SCHEMA_VERSION=6 :25）；删书：`rust/src/api.rs:354`
- 应用数据目录：`~/.local/share/RBWA/`（`rust/src/db/connection.rs:58`），译文产物建议 `translated/{book_id}/`
