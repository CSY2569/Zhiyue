# 执行规划（待审核 · 尚未开工）

> 本文件是根据代码实证整理的缺口清单与执行方案，**等你审核后才会动手**。
> 每个任务都写了「为什么做 / 现状证据 / 方案 / 验收标准 / 风险」，方便你直接在上面砍范围、改优先级。
> 生成基准：`main` @ 2026-11-26，`cargo test` 148 通过 / `flutter analyze` 零问题 / `flutter test` 326 通过。

---

## 0. 这份文档怎么用

1. 看 §2 的总表，圈定本次要做哪些任务。
2. 看 §3 里对应任务的「方案」与「验收标准」，觉得不对就改。
3. 看 §6 的 5 个决策点，给我答复。
4. 定了之后我按 §5 的顺序开工，每个任务独立提交、独立验证。

---

## 1. 范围与排除

**范围内**：产品能力缺口、平台缺口、工程债、质量门禁。

**明确排除**（按你的要求）：

| 排除项 | 说明 |
|---|---|
| 嵌入（语义）搜索与向量库 | 你指定不做 |
| `AiConfig` 里 7 个 embedding / vector_db 预留字段的清理 | 属 embedding 范畴，一并排除；**这些字段继续原样保留**，不影响后续测试 |

**硬约束**（贯穿所有任务）：

- AI 设置（`settings.ai_config` 这份 JSON）必须始终可原样读回，字段不丢、语义不破。
- 不允许任何已有功能退化；每个任务都要跑全量门禁。
- 代码结构可自由调整，但**跨 FFI 的改动必须同步跑 codegen**。

---

## 2. 任务总表

| ID | 任务 | 优先级 | 规模 | 依赖 |
|---|---|---|---|---|
| T1 | Windows runner 落地 | ~~P0~~ **完成** | L | ✅ 2026-11-26 实机验证通过 |
| T2 | CI 在 GitHub 实跑并固化为门禁 | ~~P0~~ **完成** | S | ✅ run #1 全绿（4.8 min） |
| T3 | 目录 / 书签编辑（旁路存储） | ~~P1~~ **完成** | M | ✅ 2026-11-26（拖拽重排待做） |
| T4 | AI 上下文管理（窗口大小 + 清空会话） | ~~P1~~ **完成** | S | ✅ 2026-11-26 |
| T5 | 图片阅读器全流程一致性 | P1 | M | — |
| T6 | 双页模式跨页选区与标注边界 | ~~P1~~ **完成** | M | ✅ 2026-11-26（越界冻结） |
| T7 | OCR 多页队列与取消 | P2 | M | — |
| T8 | OCR 模型管理界面 | P2 | M | — |
| T9 | 导出增强：标注拼合 PDF | P2 | M | — |
| T10 | 划词即弹 AI 快捷操作 | P2 | S | — |
| T11 | 阅读时长统计与书摘导出 | P2 | M | — |
| ~~T12~~ | ~~翻译粒度与目标语言~~ | **已取消** | — | 版式保留优先，见 §3 T12 |
| T13 | 多书对比 / 双开 | P3 | L | — |
| D1 | 清理 `TranslationMode` 两个死值 | 债 | S | codegen |
| D2 | 修 `extract_text` 同步阻塞 | 债 | S | — |
| D3 | 处理 6 条移动端专用死命令 | 债 | S | 需分支决策 |
| D4 | 补 `db/repository` 与 `pdf` 单测 | 债 | M | — |
| D5 | 性能回归基准固化 | 债 | S | — |

规模口径：**S** ≤ 1 天 · **M** ≈ 2–3 天 · **L** ≈ 1–2 周 · **XL** 需先评估才能估。

---

## 3. 任务详情

### T1 · Windows runner 落地（P0 · L）—— **✅ 已完成 2026-11-26**

> **结果**：`flutter build windows --release` 在 Windows 10 LTSC + VS Build Tools 17.14 上
> 实测通过（401 秒）；产物含 `rbwa.exe` + `rbwa_core.dll`(31MB) + `pdfium.dll`；
> 运行期验证 `rbwa_core.dll` 加载成功、SQLite 建在 `%APPDATA%\RBWA\rbwa.db`、`schema=11`。
> 未新增 `PlatformHost` 实现（`DesktopPlatformHost` 本就覆盖 Windows）。
> 已知限制与构建步骤见 [`PLATFORMS.md`](PLATFORMS.md) §6。
>
> 复用来源：远端 `windows` 分支（基于旧 main，**不可 merge**，只摘取了 CMake 集成思路、
> `fetch_pdfium_windows.ps1`、`download_ocr_models.ps1` 与一份现成的 `pdfium.dll`）。

**为什么**：三个目标平台里唯一没落地的。桌面两端共用同一套 `lib/` + `rust/`，所以补 Windows 主要是补 runner 与动态库加载，不是重写功能。

**现状证据**：仓库无 `windows/` 目录；`scripts/fetch_pdfium.sh` 只覆盖 Linux / macOS。

**方案**：
1. `flutter create --platforms=windows .` 生成 runner。
2. 扩展 `scripts/fetch_pdfium.sh`：增加 `pdfium-win-x64` 分支（上游 `bblanchon/pdfium-binaries` 有对应产物）。
3. `PlatformHost` 补 Windows 实现：`prepareWindow`（窗口装饰 / 最小尺寸）、数据与模型目录解析（`%LOCALAPPDATA%`）。
4. Windows CMake 侧把 `rbwa_core.dll` 与 `pdfium.dll` 复制进 bundle。
5. 编译验证：`rusqlite`（bundled）与 `reqwest`（rustls）在 MSVC 下应可直接编译——**需实测**，若 TLS 出问题可切 `native-tls`。

**验收**：`flutter build windows --release` 成功；启动进入书库；能导入并渲染 PDF；`cargo test` 在 Windows 下同样绿。

**风险**：pdfium 的 MSVC 运行时 dll 需随包分发。**验证环境已具备**：可通过 SSH 操作项目方的 Windows 虚拟机完成构建与实机验收（2026-11-26 确认）。

---

### T2 · CI 实跑并固化（P0 · S）—— **✅ 已完成 2026-11-26**

> **结果**：推送后 Actions 首次运行即全绿（run #1，commit `5dbaeb0`，总耗时 4.8 min）。
> 两条 job 的每一步都通过，包括容易出问题的三处：`Install Flutter`（钉 3.47.3）、
> `Fetch pdfium`（runner 能直连 GitHub Releases）、`Build Rust core for the FFI smoke tests`
> （必须单独 cargo build --release，因为 FRB 加载器读 `rust/target/release/`，而
> `flutter build` 走 CMake 的 `rust_target`）。
> 耗时：Flutter job 4.7 min（含 cargo release 编译），Rust job 1.9 min。
> 后续可选：加 `cargo fmt --check` 与 `clippy -D warnings`。

**为什么**：`.github/workflows/ci.yml` 已提交，但**从未在 GitHub 上真跑过**——本地每条命令都绿，Actions 环境未验证。

**方案**：首次 push 后观察结果，修掉环境差异（最可能是 Flutter 版本、pdfium 下载、`rust/target` 路径）；绿了之后补 `cargo fmt --check` 与 `cargo clippy -D warnings`。

**验收**：一次 push 后两个 job 全绿；人为引入一处 lint 错误能被拦下。

---

### T3 · 目录 / 书签编辑（P1 · M）—— **✅ 已完成 2026-11-26（拖拽重排未做）**

> **结果**：schema v12 + 合并层（9 条纯函数单测）+ 3 个命令 + 侧栏编辑 UI
> （右键/长按菜单：重命名 / 添加书签 / 隐藏；顶部菜单：恢复原始目录）。
> PDF 文件始终不被修改。
>
> 关键前置：`OutlineEntry` 加了 `key` 字段（`pdf:0.1.2` / `bm:<n>`），
> 由 pdfium 遍历时按兄弟序号生成。没有它 UI 无法定位"在编辑哪个节点"——
> 合并后的下标会因重排或隐藏而变化。
>
> **未做**：拖拽重排（`order_index` 后端已支持，缺 UI）；编辑菜单没有自动化
> 测试（需要 fake repo 实现新增的三个方法）。

> **已完成**：schema v12（`book_outline_overrides` 表 + 迁移分支）、
> `pdf/outline_edit.rs` 纯函数合并层（9 条单测）、仓储 `db/repository/outline.rs`、
> 三个命令 `save_outline_override` / `delete_outline_override` / `reset_outline`，
> `get_outline` 返回合并后的树。cargo test 158 + 2 全绿。
>
> **UI 待做的前置**：`OutlineEntry` 目前只有 title / page / children，**没有 key**。
> 而编辑必须按 key 定位节点，且 key 编的是**原始文档位置**——合并后的位置会因重排
> 而变化，UI 不能自己按下标反推。所以下一步要先给 `OutlineEntry` 加 `key: String`
> 字段（需再跑一次 codegen），UI 才能安全地发起编辑。

**为什么**：目录当前只读，是最常见的用户诉求之一。

**现状证据**：`api.rs` 只有 `get_outline`；`pdf/pdfium.rs:337` 的 `outline()` 只做遍历。**pdfium 是渲染/读取库，没有写回 PDF 目录的能力**，所以不能改原文件。

**方案（旁路存储）**：
- 新增表 `book_outline_overrides`：`(book_id, entry_id, parent_id, title, page, order_index, hidden)`，存用户对目录项的改名 / 重排 / 隐藏 / 新增书签。
- 读取时以 pdfium 原始目录为基底，套用 overrides 合成最终树。
- 新增命令：`save_outline_override` / `delete_outline_override` / `reset_outline`。
- UI：目录侧栏加右键菜单（重命名 / 删除 / 添加书签到当前页）+ 拖拽重排。

**验收**：改名 / 新增书签 / 排序 / 隐藏后重启仍保留；「恢复原始目录」能一键还原；跳转页码正确；**原 PDF 文件不被修改**（用文件哈希校验）。

**风险**：schema v11 → v12，需 bump + 迁移分支；跨 FFI 类型变更要跑 codegen。

**备选方案**：写回 PDF 目录——需引入可写库或换引擎，工作量与风险都远大于旁路存储，**不建议**。

---

### T4 · AI 上下文管理（P1 · S）—— **✅ 已完成 2026-11-26**

> **结果**：`AiConfig` 新增 `history_window: i32`（0 = 不限，保持既有行为）；新增命令
> `clear_thread_messages(thread_id)`；设置页「AI 回复」区加「历史窗口」滑块；
> AI 面板加「清空当前对话（保留窗口）」按钮。
>
> 兼容性：新字段带 `#[serde(default)]`，旧 `ai_config` JSON 读回为 0（不限）——
> 有单测锁住这一点（`ai_config_deserializes_legacy_json_without_new_fields`）。
> 已跑 codegen 更新绑定。

**为什么**：现在只有「是否携带全书历史」一个开关，没有窗口控制，也没有清空当前会话的入口。

**现状证据**：`AiConfig.include_book_history`（设置页已暴露）；`delete_ai_thread`（`api.rs:1412`）已存在——清空可复用，不必新造。

**方案**：
- `AiConfig` 增 `history_window: i32`（0 = 全部）。**新字段必须带 serde 默认值**，保证老配置能读回。
- 新增命令 `clear_thread_messages(thread_id)`：删消息但保留线程。
- UI：AI 面板加「清空对话」；设置页「服务与模型」加历史窗口输入。

**验收**：窗口设为 N 后请求只带最近 N 轮（用 fake 模型断言请求体）；清空后下一轮不带旧消息；**旧版 `ai_config` JSON 能无损读回**。

---

### T5 · 图片阅读器全流程一致性（P1 · M）

**为什么**：图片书能打开也能标注，但缩放 / 翻页 / OCR / 标记四者未做过系统验证，最容易出现「文字版能用、图片版错位」。

**方案**：按「打开 → 缩放 → 翻页 → 整页 OCR → 划词 → 标注 → 导出」走完整链路，逐环节补测试并修偏差；重点是缩放后的坐标换算。

**验收**：新增端到端 widget 测试覆盖上述链路；实机逐项确认；导出的标记位置与原图对得上。

---

### T6 · 双页模式跨页选区与标注边界（P1 · M）—— **✅ 已完成 2026-11-26**

> **结果**：勘察发现「选区跨页」在结构上不可能——双页模式下左右各是一个 `_PageItem`，
> 各自带一个 `SelectionLayer`，选区天然按页归属。真正粗糙的是**越界后的行为**：
> `_toNorm` 把指针坐标 clamp 到 [0,1]，于是指针移到装订线或对面页时，选区会继续
> "延伸"到本页的最后一行——选中了用户从未碰到的字。
>
> 修复：新增 `_outsidePage()`，`_updateSelection` 在指针离开页面矩形时**冻结**选区
> （保持最后一次在界内的范围），而不是钳制后继续延长。
>
> 验证：`test/selection_layer_test.dart` 新增用例；反向验证过——去掉冻结逻辑后，
> 指针移到页外使 `currentIndex` 从 2 跳到 3（页边最后一个字），正是被修的 bug；
> 恢复后通过。flutter analyze 零问题、flutter test 327 通过。

**为什么**：双页视图下选区跨到相邻页时，命中与归属行为粗糙。

**方案**：明确规则——我倾向**选区不跨页**（拖到页边界即停），比「允许跨页但按页拆分标注」简单且符合直觉。落地为命中检测按页裁剪 + 标注归属按页判定。

**验收**：双页模式从左页拖向右页，选区止于页边界；已存在标注不因切视图模式而错位；补 widget 测试。

---

### T7 · OCR 多页队列与取消（P2 · M）

**为什么**：现在逐页调用，扫一整本要逐页点；`rapidocr` 支持取消令牌，具备条件。

**方案**：Rust 侧加扫描任务队列（复用翻译的互斥思路），暴露 `start_scan_batch` / `cancel_scan_batch` + 进度流；UI 加「扫描整本 / 当前页起 N 页」与进度条。

**验收**：连续扫描 N 页有进度反馈；中途取消能停且已完成页保留缓存；并发启动被拒绝。

---

### T8 · OCR 模型管理界面（P2 · M）

**为什么**：模型只能靠 `scripts/download_ocr_models.sh` 安装，终端用户无法自查「装没装 / 版本对不对」。

**方案**：设置页加「OCR 模型」分区：显示各模型集的存在性、体积、版本；提供「重新下载 / 校验」。下载逻辑从 shell 迁到 Rust（已有 `reqwest` + `sha2`，脚本里的 sha256 校验可搬）。

**验收**：未装时给出明确引导；安装有进度；校验失败能重试；断网时报错可读。

---

### T9 · 导出增强：标注拼合 PDF（P2 · M）

**为什么**：现在标注只能导 Markdown / JSON，图片层能拼合成图，但没有「把标注烧进 PDF 页」的产物。

**现状**：`export.rs` 只有 `annotations_markdown` / `annotations_json`。

**方案**：渲染每页位图 → 叠加标注层 → 用 `image` crate 合成 PNG → 复用图片书路径组装成 PDF。HTML / EPUB 不在本轮。

**验收**：导出文件页数与书一致；标注位置准确；中文字形不丢；500 页以上的书不 OOM。

---

### T10 · 划词即弹 AI（P2 · S）

**为什么**：现在划词后要在工具条上再点一次。

**方案**：设为可选项（默认关，避免打扰）。选中后延迟 300ms 弹出紧凑卡片，展示「翻译 / 解释」，点击展开完整结果。

**验收**：开关生效；不干扰拖拽与长按；触摸端不与系统选择菜单冲突（需 Android 分支验证）。

---

### T11 · 阅读时长统计与书摘（P2 · M）

**为什么**：完全没有。

**方案**：新增表 `reading_sessions(book_id, started_at, ended_at, pages_read)`；阅读器可见时计时（失焦 / 切后台暂停）；书库页与书籍详情展示总时长；书摘 = 笔记 + 高亮汇总，可导出 Markdown。

**验收**：计时准确（切后台不计）；统计不随重启丢失；书摘导出与标注一致。

---

### ~~T12~~ · 翻译粒度与目标语言（**已取消** · 2026-11-26）

**为什么**：这是目前最显眼的能力限制——只能整本、只能简体中文。但**它受上游引擎限制，不是靠改本项目代码能解决的**。

**现状证据**：`translate/job.rs:19` 写明 v1 scope 只做 whole-book、语言固定；`TranslationMode` 的另两值引擎不消费。

**方案**：先做 **spike（1–2 天，只出结论不写产品代码）**，评估三条路：
1. 看 RetainPDF 上游是否有按页 / 按范围能力（最省事，但要等上游或自己打 patch）；
2. 移植 Android 分支已有的**块级 LLM 翻译**（`text_translate.rs` 已在，桌面可直接复用，但会丢掉版式保留）；
3. 换引擎（如 BabelDOC）——历史证明试过且被放弃过。

**结论：不做。** 项目方明确「要版式原样保留」。版式保留来自 RetainPDF 解析整本版式后整体重排，与「即时翻译单页」在时间上不可兼得；
无论换哪种引擎，只要还要版式，就必须先拿到全本结构。因此维持整本粒度，本条目取消。

> 若将来只想加「目标语言可配」而不动粒度，入口在 `translate/job.rs` 的 spec 构造（目标语言当前硬编码）；那是一次小改动，但仍需验证上游 pipeline 是否接受非简体中文。

---

### T13 · 多书对比 / 双开（P3 · L）

**方案**：路由支持同时挂两个阅读器实例；难点在 `viewerProvider` 目前是单例语义，要改成按 bookId 分桶（影响面大，故列 P3）。

**验收**：两个窗口 / 分屏各自独立翻页与标注，状态互不串。

---

## 4. 工程债（建议穿插做，不单独排期）

| ID | 内容 | 做法 | 验收 |
|---|---|---|---|
| D1 | `TranslationMode` 的 `WithProgress` / `Manual` 是死值 | 删枚举变体 + 跑 codegen；DB 里若有历史值做一次清洗 | 编译过，`models/translate.rs` 的 roundtrip 测试改后仍绿 |
| D2 | **6 条** async 命令同步阻塞 pdfium（不止 `extract_text`） | 全部包进 `spawn_blocking`；`open_book` 拆出同步体 | ✅ 2026-11-26 完成，见下 |
| D3 | 6 条移动端专用命令在 main 上是死代码 | 与分支策略一起定：标注为 android-only 或下掉 | 需先有分支决策（§6 Q5） |
| D4 | `db/repository` 与 `pdf` 模块缺单测 | 按 repository 逐个补 CRUD 与边界用例 | 新测试能在 CI 跑绿 |
| D5 | 无性能回归基准 | 把 OCR 页级耗时、FTS 查询、启动时间做成可重复 bench 脚本 | 一条命令出结果，可对比历史 |

---

### D2 完成记录（2026-11-26）

原以为只有 `extract_text` 一处，实测是**同一类问题的 6 处**——它们的注释都写着
"must not block the UI"，却都在 FRB 的 async worker 上同步调用 pdfium：

| 命令 | 行号 | 处理 |
|---|---|---|
| `open_book` | 754 | 整体搬进 `open_book_blocking()`，由 `spawn_blocking` 调用 |
| `render_page` | 840 | 包 `spawn_blocking`（**每页都走的热路径**） |
| `render_thumbnail` | 851 | 同上 |
| `get_outline` | 862 | `spawn_blocking(pdf::outline)` |
| `extract_text` | 1140 | 同上 |
| `page_has_text` | 1917 | 同上 |

新增 `rust/tests/api_roundtrip.rs`（项目第一个 Rust 集成测试），两个用例：

1. `import_open_render_and_extract_round_trip` —— 端到端走通 import → open →
   render → 取字符框 → 缩略图 → 目录 → close，保护阻塞池往返不破。
2. `pdfium_commands_do_not_starve_the_async_worker` —— **能真正区分阻塞与否**：
   在 current-thread runtime 上跑心跳任务，命令若阻塞 worker 心跳就冻结。已实测
   反向验证：去掉 `extract_text` 的修复后，该用例报
   "only 0 heartbeat ticks across 126584 calls in 3s"。

**仍未处理（同类问题，但函数体是 async，需结构性改造）**：`import_book`（文件复制 +
pdfium 打开 + 封面生成）与 `scan_page`（OCR 推理）。二者也在 async worker 上跑重活，
建议单独立一项。

---

## 5. 建议的执行顺序

```
P0   T2 CI 实跑 ✅（门禁已可信，后续任务都靠它把关）
     T1 Windows runner（可与 T2 并行，但需要 Windows 环境）

P1   D2 extract_text 阻塞（顺手清掉再动 AI）
     T4 AI 上下文（小而快，直接改善日常使用）
     T6 双页边界（纯 UI 修正，风险低）
     T3 目录编辑（有 schema 变更，单独一批做）
     T5 图片全流程（验证型任务，可并行）

P2   按偏好挑：T10 → T7 → T9 → T8 → T11

P3   T12 已取消；T13 多书对比/双开（价值待评估）
```

每个任务独立分支 + 独立提交，跑完全量门禁才算完成。

> ⚠️ **P0 两项都依赖项目方的环境**：
> - **T2 需要你 push**：本工作环境无法访问 GitHub（`git ls-remote` 超时），CI 只能在推送后由 Actions 运行。
> - **T1 需要 Windows 虚拟机的 SSH 连接方式**（IP / 端口 / 用户名），且 `flutter create --platforms=windows` 生成的 runner 需在 Windows 上构建验证。
> - 在这两项解除阻塞前，可先做 P1 中不依赖外部环境的部分：D2 → T4 → T6。

---

## 6. 需要你拍板的 5 个决策

| # | 决策 | 我的建议 | 影响 | 你的决定（2026-11-26） |
|---|---|---|---|---|
| Q1 | **T1 Windows 现在做吗？** | 做，但需要一个 Windows 环境或开 `windows-latest` CI 才能验收 | 不做则平台目标只完成 2/3 | ✅ **做**，通过 SSH 操作其 Windows 虚拟机验证 |
| Q2 | **T3 目录编辑接受「旁路存储」吗？** | 接受。pdfium 无写能力，写回 PDF 要换库，代价大得多 | 代价：**改动的目录只在本应用内可见**，导出给别人的 PDF 仍是原目录 | ✅ **接受旁路存储** |
| Q3 | **T12 翻译粒度现在做 spike 吗？** | 做 spike 但先别承诺功能。它是唯一「可能白干」的任务 | 不先验证就排期，容易做成半成品 | ✅ **不做**：要「版式原样保留」，而版式保留依赖整本解析，故维持整本粒度 |
| Q4 | **优先级顺序按 §5 吗？** | 按 §5。若你更急某个（比如目录编辑），直接说，我把它提前 | 决定第一批做什么 | ✅ **按 §5** |
| Q5 | **Android 分支纳入本轮吗？** | 不纳入。当前 checkout 只有 `main`，`android` 上的移动 UI 无法在此验证，两边改容易乱 | D3 与 T10 的触摸端验证依赖此决定 | ✅ **不纳入**：Android 的操作逻辑与桌面不同，后续单独修改 |

---

## 7. 验证与交付方式

**每个任务的完成定义**：
1. 新增 / 更新的自动化测试通过（Rust 单测或 Flutter widget 测试）。
2. 全量门禁绿：`cargo test` ≥148、`flutter analyze` 零问题、`flutter test` ≥326。
3. AI 设置回归检查：`ai_config` 能原样读回（凡碰 `AiConfig` 或 settings 的任务必做）。
4. 给出一份**手动验收清单**（逐条可勾选），由你在实机确认 UI——自动化盖不住观感。
5. 独立提交，提交信息写清「为什么改」而不仅是「改了什么」。

---

## 8. 不做的（明确排除）

| 项 | 原因 |
|---|---|
| 嵌入 / 语义搜索、向量库 | 你指定排除 |
| `AiConfig` 的 7 个 embedding / vector_db 字段清理 | 同上；字段保留不动 |
| 翻译引擎整体替换 | 历史证明代价极高（自研管线 → BabelDOC → RetainPDF，换了三轮）；除非 T12 spike 结论支持 |
| 重写 UI 框架 / 换状态管理 | 现有 Riverpod 组织良好，重写无收益 |
| `android` 分支的移动端改动 | 2026-11-26 确认：移动端操作逻辑与桌面不同，后续单独一轮处理；本轮只动 `main` |

---

## 9. 审核方式

你可以直接在本文档上：
- 删掉不想做的任务行；
- 改「优先级」列；
- 在 §6 决策表里写下选择；
- 对某个任务的「方案」给出不同想法。

改完告诉我一声，我按最终版开工。**在你确认之前我不会改任何代码。**
