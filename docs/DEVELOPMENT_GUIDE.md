# 二次开发交接指南（智阅 / RBWA）

> 本文档由一次全仓只读勘察生成，面向接手二次开发的工程师。
> 所有路径锚点均经实际读取核验；标注「待核」的是勘察中未能实证的推断。
> 生成时点：分支 `main` @ `30a66a0`（工作树有未提交改动，见 §12）。

---

## 1. 项目速览

| 项 | 值 |
|---|---|
| 名称 | 智阅 ZhiYue（内部代号 RBWA，pubspec `name: rbwa`，crate `rbwa_core`） |
| 形态 | 本地文档阅读器：PDF（文字版/扫描版）+ 图片，划词翻译/解释/搜索，离线 OCR，标注 |
| UI | Flutter（Dart）120 文件 / 32,238 行 |
| 核心 | Rust 17,122 行（不含 `frb_generated.rs`） |
| FFI | flutter_rust_bridge v2.12.0（版本四处硬绑，见 §8） |
| 状态管理 | flutter_riverpod 2.6（无 codegen，手写不可变状态类） |
| 目标平台 | `main` = Linux/Windows 桌面；`android` = Android arm64 |
| 许可 | GPL-3.0（有传染性，见 §11） |
| 提交历史 | 161 commits |

**分工原则（全项目第一约束）**：所有重活与数据在 Rust 侧——PDF 渲染、OCR、AI 网络、SQLite、搜索索引、翻译编排；Flutter 只负责绘制与交互。

---

## 2. 分层架构

```
lib/features/*           UI：绘制与交互，Riverpod 本地状态
lib/data/repositories/*  数据层：把 UI 需求译成 FRB 调用，把 Rust 返回值转成 Dart 形状
═══════ flutter_rust_bridge v2 ═══════   仅 rust/src/api.rs 的 pub fn 可跨边界
rust/src/*              核心：全部重活与持久化
```

**跨边界铁律**（`docs/ARCHITECTURE.md` §1，已实证）：
- 只有 `rust/src/api.rs` 的 `pub fn` 会被导出；其它模块的 `pub` 项不跨边界。
- 跨边界类型必须定义在 `rust/src/models/`，且是 plain struct/enum。
- Dart 侧**调用**只允许经 `lib/data/repositories/`；**类型**可直接 import `lib/src/rust/models/*`。
  实测：`lib/features` 内 `rust.<fn>(` 调用 0 处（唯一一处在 `lib/platform/desktop/desktop_host.dart:42` 的 `rust.initCore()`），
  但有 **46 个文件** import 生成模型/枚举——这是有意为之的类型透传，不是违规。
- 生成物不得手改：`rust/src/frb_generated.rs`、`lib/src/rust/**`。

---

## 3. 目录地图

| 路径 | 内容 |
|---|---|
| `lib/main.dart` | 启动：平台 host → `RustLib.init()` → `initCore()` → `ProviderContainer` → `runApp` |
| `lib/app.dart` | 根 widget：主题合成、`MaterialApp.router`、冷启动外部文件导入 |
| `lib/router/app_router.dart` | go_router：`ShellRoute` 包无边框标题栏，5 条路由 |
| `lib/core/` | theme（5）、widgets（8）、settings store、layout_breakpoints、lru_cache、haptics、navigation、utils |
| `lib/data/repositories/` | 6 个仓库：library(89) reader(212) ai(98) translation(108) search(27) settings(19) 行 |
| `lib/features/` | 9 模块 77 文件 17,423 行，见 §4 |
| `lib/platform/` | `platform_host.dart`(135) 抽象 + `current.dart`(16) 选择 + `desktop/desktop_host.dart`(62) |
| `lib/src/rust/` | FRB 生成物（11 文件 11,886 行），勿手改 |
| `rust/src/api.rs` | FFI 聚合层，2,936 行，81 命令 |
| `rust/src/models/` | 跨边界数据结构 |
| `rust/src/db/` | `connection.rs`(788，含迁移链) `schema.rs`(341，DDL) `repository/`(12 个) |
| `rust/src/pdf/` | pdfium 封装 + 图片书；进程级 `PDFIUM_LOCK` 串行 |
| `rust/src/ocr/` | `engine.rs`(891) PP-OCRv4 双模式，懒加载 |
| `rust/src/ai/` | 手写 SSE `openai.rs`(1497) + `web_search.rs`(479) + `prompts.rs`(440) + `search_safety.rs`(248) |
| `rust/src/search/` | FTS5 + jieba，后台建索引 |
| `rust/src/translate/` | 4,313 行：`flat_ocr.rs`(1655) `job.rs`(1250) `text_translate.rs`(772) `engine.rs`(322) |
| `rust/src/export.rs` | 标注导出 Markdown/JSON（纯函数） |
| `rust/src/error.rs` | `AppError` 7 变体 |
| `scripts/` | setup / fetch_pdfium / download_ocr_models / build_packages / sync-from-main |
| `third_party/retainpdf/` | vendored 翻译引擎（54MB，钉死上游 commit，MIT） |
| `test/` | 60 测试文件 + 9 helpers |

---

## 4. Flutter feature 模块

| 模块 | 职责 | 关键文件 |
|---|---|---|
| library | 书架：网格/分类/筛选/导入/批量 | `library_page.dart`(433) `providers/library_providers.dart`(346) `widgets/category_rail.dart`(526) |
| reader | 阅读器宿主：页滚动渲染/缩放翻页/侧栏/面板布局 | `widgets/pdf_page_scroll.dart`(1152) `reader_page.dart`(667) `providers/viewer_provider.dart`(220) |
| annotation | 两层标注：文本层选区 + 图像层标记 | `widgets/image_mark_layer.dart`(774) `widgets/selection_layer.dart`(673) `selection_geometry.dart`(430) |
| ai | AI 对话：多书会话/流式聊天/结果卡/识图 | `providers/ai_provider.dart`(609) `widgets/result_card.dart`(455) |
| search | 全文搜索：索引轮询 + 命中高亮 | `providers/search_providers.dart`(184) `search_page.dart`(253) |
| bilingual | 对照阅读：引擎状态/整书翻译流/译文缓存 | `widgets/translated_pane.dart`(466) `widgets/translation_settings_section.dart`(456) |
| screenshot | 自由截图 → 直接送识图 | `free_screenshot_overlay.dart`(282) |
| settings | 设置页（8 个 SettingsSection 挂载点） | `settings_page.dart`(928) |
| shell | 无边框标题栏 | `app_title_bar.dart`(128) |

### 状态管理约定
- 位置固定：`features/<mod>/providers/*.dart`；仓库 provider 与仓库同文件。
- 状态类**手写不可变类 + copyWith**（无 freezed / 无 build_runner，见 `features/library/models/library_filter.dart:19` 注释）。
- 四种写法并存按语义选：`Notifier`（命令式状态）、`AsyncNotifier`（DB 列表）、`StateNotifier`（阅读器视图态）、`Provider`/`StateProvider`（派生值与开关）。
- **autoDispose 全仓仅 1 处**（`bilingual/providers/book_translation_provider.dart:165`）；其余 provider 进程级常驻，缓存靠 `core/lru_cache.dart`。新增跨书 provider 必须自行 `ref.onDispose` 清缓存。
- 跨模块共享：下游 `ref.watch(upstream.select(...))` 收窄重建（例 `annotation/providers/annotation_provider.dart:27`）；反向刷新用 `ref.invalidate`。

---

## 5. 启动链路（实测）

`lib/main.dart:22-45`：
1. `:23` `WidgetsFlutterBinding.ensureInitialized()`
2. `:24` `PlatformHost.install(platformHost)`
3. `:27` `await host.prepareWindow()` —— 桌面端建 1280×800 无边框窗口
4. `:30` `await RustLib.init()` —— 装载 `librbwa_core.so`
5. `:32` `await host.initCore()` —— Rust 内开库/建表/迁移/tracing，Dart 仅收 `InitResult{ok, dbPath, schemaVersion}`
6. `:36-37` 显式 `ProviderContainer()` + `host.attachLifecycle(container)`
7. `:39-44` `runApp(UncontrolledProviderScope(...))`

`_Bootstrap` `:50`：Android 首次启动装 ~210MB OCR 模型；`coreInit == false` 时停在「数据初始化失败」页——因为 release 的 `panic = "abort"`，进库后任何 DB panic 会直接杀进程。

`RbwaApp` `lib/app.dart:23` → `MaterialApp.router(routerConfig: appRouter)` → `ShellRoute`（`app_router.dart:61`）= 标题栏 + 路由出口；`initialLocation: '/library'`（`:59`）。

---

## 6. FFI 面与「新增一个命令」

`rust/src/api.rs` 实测：**81 个 `pub fn`，其中 19 个 `async`，0 个返回 `Result`**，4 个用 `StreamSink` 做流式（`stream_chat`:1661、`stream_vision_png`:1719、`install_engine`:2180、`translate_book`:2239）。

命令按里程碑分节：初始化/设置 7、书库 14、阅读器/PDF 8、文本标注 8、图像标注 4、AI 10、OCR 4、搜索 3、对照阅读 1、翻译引擎 11、文本级双语 11。

### 端到端步骤
1. 类型 → `rust/src/models/<domain>.rs`，并在 `models/mod.rs` 注册（plain struct/enum）。
2. 命令 → `api.rs` 对应节内加 `pub (async) fn`，遵守三条既有模式：
   - **不外抛错误**：返回带 `pub error: Option<String>` 的结构体（`InitResult` `api.rs:43` 为范式，同模式 10 处）；集合类失败返回空 vec。
   - **阻塞重活必须 `spawn_blocking`**（现存 3 处：`api.rs:1060`、`api.rs:2327`、`translate/job.rs:150`），否则占死 FRB 的 async worker。
   - **feature 门控成对写** `#[cfg(feature="x")]` + `#[cfg(not(feature="x"))]` 桩（范式 `translate_book` `api.rs:2239`）。
3. 实现 → 落到 `pdf`/`ocr`/`ai`/`search`/`translate`/`db::repository`，`api.rs` 只做参数转换与错误字符串化。
4. 生成 → `flutter_rust_bridge_codegen generate`（配置 `flutter_rust_bridge.yaml:8-11`）。
5. Dart → `lib/data/repositories/<x>_repository.dart`：`import 'package:rbwa/src/rust/api.dart' as rust;` 后直调。

> ⚠️ 改了 `api.rs` 却不跑 codegen，运行期会因 `rustContentHash` 不匹配失败（当前值 `507000550`，见 `lib/src/rust/frb_generated.dart:74`）。

---

## 7. 数据库

`SCHEMA_VERSION = 11`（`rust/src/db/schema.rs:40`）。13 张实体表 + 1 张 FTS5 虚表：

`categories` · `books`（`original_path` UNIQUE 去重，v11 加 `content_hash`）· `reading_progress` · `annotations` · `image_annotations` · `page_ocr_cache`（PK book_id,page,ocr_mode）· `page_text_index` · `page_text_fts`（FTS5 external-content + 触发器同步）· `ai_threads` · `ai_messages` · `translation_glossary` · `page_text_translation` · `settings`（API key 唯一落点）· `schema_version`。

**迁移机制**：`connection.rs:173` 的 `migrate` 在一个 `unchecked_transaction` 内按 `SELECT MAX(version)` 逐版本 `match` ALTER（v1→v11 共 10 步，`:205-292`）；每步配 `has_column`（`:141`）保证幂等，半提交的库能自愈。版本不匹配只 warn 不迁移（`:302-307`）。

PRAGMA：WAL + `foreign_keys` + `synchronous=NORMAL`（`schema.rs:337-341`）。

---

## 8. 环境、构建、测试

### 从零跑起来
```bash
sudo bash scripts/setup.sh          # pacman 系统依赖 + FRB codegen（不装 Flutter，仅检测）
# 手工装 Flutter SDK 到 ~/develop/flutter，加 PATH，重开终端
flutter doctor
flutter pub get
bash scripts/fetch_pdfium.sh        # 构建前置，需网络 → rust/libpdfium/libpdfium.so
flutter build linux --release       # CMake 内部自动 cargo build
./build/linux/x64/release/bundle/ZhiYue    # 或 flutter run -d linux
bash scripts/download_ocr_models.sh --all  # 可选，整页 OCR 需要
```

### ⚠️ 两套 cargo 目标目录（最容易踩的坑）
- CMake 把产物放进 `build/**/rust_target`（`linux/CMakeLists.txt:59`，`CARGO_TARGET_DIR` 覆盖）。
- 但 Dart 测试加载器固定读 **`rust/target/release/`**（`lib/src/rust/frb_generated.dart:79` 的 `ioDirectory`）。
- 结论：`flutter build linux` 成功 **≠** `flutter test` 能加载 `.so`。跑冒烟测试前必须另跑 `cargo build --release --manifest-path rust/Cargo.toml`。
- `rust/target` 当前已 **11 GB**；`flutter clean` 会连带清掉 `build/*/rust_target`，触发全量重编。

### 测试（以下三行均为 2026-11-26 实测，Flutter 3.47.3 / cargo 1.97.1）
| 类型 | 命令 | 实测结果 | 前置 |
|---|---|---|---|
| Rust 单测 | `cargo test --manifest-path rust/Cargo.toml` | **148 通过 / 0 失败 / 12 忽略** | 无（默认 features `pdf,ai,ocr`）；需 `libpdfium.so`，否则 PDF 用例失败 |
| Flutter 静态检查 | `flutter analyze` | **No issues found**（8.7s） | `flutter pub get` |
| Dart 全量 | `flutter test` | **326 通过 / 0 失败** | 5 个冒烟测试需 `rust/target/release/librbwa_core.so` |
| 集成 | `flutter test -d linux integration_test/scan_middle_page_test.dart` | 1 个 | **硬编码本机书籍数据**，换机不可用 |

Dart 测试构成：33 个 `testWidgets`（UI）、27 个纯 Dart/异步、5 个需真 `.so` 的冒烟（均走 `test/helpers/smoke_helpers.dart` 的 `initIsolatedCore()`，每进程隔离目录 `/tmp/rbwa-test-<pid>`）。

> 注：文档里出现过的 202 / 323 / 326 / 327 等 Flutter 计数是不同批次的验证快照，**以实测 326 为准**；Rust 侧的 130 / 144 同理，以 148 为准。

### lint
`analysis_options.yaml:10` 仅 `include: package:flutter_lints/flutter.yaml`，本地 `rules:` 为空（`:31-33`）。仓库约定（README「仓库约定」）：提交前 `flutter analyze` 与 `flutter test` 双零；截图永不提交。

### 打包
`bash scripts/build_packages.sh [version]` → `dist/zhiyue_<ver>_amd64.deb`（纯 `ar` 手工组装）、`dist/ZhiYue-<ver>-1.x86_64.rpm`、`dist/ZhiYue-x86_64.AppImage`（实测 222 MB）。bundle 内 PDF 依赖 `libpdfium.so` 7.8 MB、核心 `librbwa_core.so` 36 MB，OCR 模型打包时才注入（高精度 195 MB + 快速 15 MB）。

### 环境坑：中国镜像会污染 `pubspec.lock`
若本机设置了 `PUB_HOSTED_URL` / `FLUTTER_STORAGE_BASE_URL`（本机为腾讯镜像），`flutter pub get` 会把 `pubspec.lock` 里所有包 URL 从 `pub.dev` 改写成镜像地址，并可能顺带升级 `flutter: ">=3.41.0"` 这类 SDK 约束——**改动与你的代码无关，不要提交**。提交前 `git checkout -- pubspec.lock`。

### 版本强耦合点（改一处必改全部）
flutter_rust_bridge **2.12.0** 出现在：`pubspec.yaml:15`、`rust/Cargo.toml:24`（`=2.12.0` 精确锁）、`scripts/setup.sh:154`、生成物 `frb_generated.dart:71` 的 `codegenVersion`。

---

## 9. 平台拆分（main / android）

两条长期分支共享 `lib/` 与 `rust/`，**唯一差异文件是 `lib/platform/current.dart`**（选平台 host）；`android` 分支多出 78 个文件。

- 所有平台差异走 `PlatformHost` 抽象（`lib/platform/platform_host.dart:50-135`）：`touch`、`phoneLayout(w)`、`compactUi(w)`、`needsModelInstall`、`prepareWindow`、`initCore`、`attachLifecycle`、`ensureModels`、`wrapApp`、`takeIncomingFiles`、`translatedPane`、`readerBars`、`wrapReadingSurface`、`readerEntered/Exited`、`handleReaderKey`。
- **禁止**在新代码里写 `Platform.isAndroid`（`platform_host.dart:42-45` 明令）；纯尺寸判断用 `isCompactWidth(width)`（`core/layout_breakpoints.dart:10`）。`test/platform_boundary_test.dart` 会拦截越界引用。
- 注意抽象层**反向依赖 features**：`platform_host.dart:6-7` import 了 `features/bilingual/.../translated_pane.dart` 与 `features/reader/.../reader_toolbar.dart`，因为「对照右栏」「阅读器工具条」被写成了接口方法。

### 同步规则（有陷阱）
```bash
git checkout android && bash scripts/sync-from-main.sh main
```
**不要直接 `git merge main`**：`main` 上不存在 Android 专属文件，git 会**静默删除**它们，分支随即失去构建 APK 的能力。脚本的做法是 `merge --no-commit` 后按 `.platform/android-owned.txt` 从合并前提交逐行 `git checkout` 恢复。新增 Android 专属文件必须同步更新该清单（36 行），否则下次同步会静默删掉它。

---

## 10. 扩展点速查

| 要做的事 | 改哪些文件 |
|---|---|
| 新增 UI feature 模块 | `lib/features/<name>/{pages,widgets,providers,models}/` + `lib/data/repositories/<name>_repository.dart` + 路由注册 |
| 新增路由 | `lib/router/app_router.dart`：`ShellRoute.routes`（`:91-120`）+ 扩 `ShellDestination`（`:21`）+ `shellDestinationFor`（`:23`）+ `titleBarInfoFor` 的 title switch（`:38-46`）。漏改后两者标题栏会显示成「智阅」且不显示返回 |
| 新增 Rust 命令 | §6 五步 |
| 新增平台差异 | 加 `PlatformHost` 成员（给默认实现）+ 各平台 host 覆写 + 改 `current.dart` |
| 新增设置项 | `features/settings/settings_page.dart` 插 `SettingsSection`（现有 8 处挂载点）+ KV 走 `settings_repository` / `core/settings/settings_store.dart` |
| 新增数据库表 | `rust/src/db/schema.rs` 加 DDL + **bump `SCHEMA_VERSION`** + `connection.rs` 的 `migrate_body` 加一步 ALTER（配 `has_column` 幂等） |

---

## 11. 许可证约束（影响能否闭源）

- 项目本体 **GPL-3.0**：任何衍生分发必须整体开源。想闭源发行不可行，除非换取授权。
- 唯一 **AGPL** 构件是 PyMuPDF（`fitz`，随 RetainPDF 引擎分发）。它经**独立子进程**调用，故不传染本体（GPLv3 §13）；维护约定明令新增 copyleft 组件必须保持独立进程、不得链进 `librbwa_core`（`docs/THIRD_PARTY.md:55-57`）。
- 其余：pdfium BSD-3、Flutter BSD-3、PP-OCRv4 Apache-2.0、ONNX Runtime MIT、Typst Apache-2.0、思源宋体 OFL-1.1（有 Reserved Font Name 改名义务）、pikepdf MPL-2.0。
- Android 包**不含** RetainPDF/CPython/PyMuPDF/Typst，走块级 LLM 翻译，移动端无 AGPL 负担。

---

## 12. 当前工作树状态（交接必读）

`git status` **不干净**：3 个文件有未提交改动，是一处**进行中的 AI 识图路由修复**（+158 / −17）：

- `rust/src/ai/mod.rs`：新增 `vision_model()` / `vision_route()` / `non_blank()`，统一决定识图请求实际使用的 `(base_url, api_key, model)`。规则是：通用模型声明支持图片时，独立的识图覆盖配置**全部失效**（避免历史遗留的 base_url/key 把识图请求劫持到旧 provider）；纯文本通用模型才用覆盖项，空串回退。
- `rust/src/api.rs`：新增 `ensure_vision_api_key()`，把空 key 校验从硬编码 `config.api_key` 改为跟随 `vision_route()`，`stream_vision_png` 改用之。
- `rust/src/ai/openai.rs`：`AiClient` 实现接入新路由 + 新增 4 个单测（`vision_route_prefers_general_config_when_model_supports_vision` 等）。

**判断**：改动内聚、有测试、未见半成品痕迹，是一个可完成的修复。`stream_vision_png` 签名未变，因此**不需要重跑 codegen**。

**已实测（2026-11-26）**：该改动在树上的状态下 `cargo test` 为 148 通过 / 0 失败 / 12 忽略，其中包含它新增的 4 个识图路由单测。即**这份未提交改动是绿的**，可作为基线继续开发。

---

## 13. 文档现状：不一致清单与修复状态

`docs/` 有 250 KB 存量文档，多处曾滞后于代码。下表 §1–§11 已于 2026-11-26 修正（26 insertions / 27 deletions，仅文本）；**§4 / §6 / §8 / §10 / §12 仍是遗留问题**，需要判断而非机械替换。

| # | 问题 | 状态 |
|---|---|---|
| 1 | README 声称本分支是 `feat/retain-engine`，该分支已不存在 | ✅ 已改为 `main`（另修 `DIAGRAMS.md:3` 同源表述） |
| 2 | 死链：`docs/ANDROID_V1_PLAN.md`、`ANDROID_PACKAGES.md` 在 main 上不存在 | ✅ 已改为「见 android 分支」的纯文本引用 |
| 3 | schema 版本过期：文档写 v9，实际 11（`schema.rs:40`） | ✅ `DIAGRAMS.md` 5 处 + `FEATURES.md:230` 已改 v11 |
| 4 | 目标平台自相矛盾：`IMPLEMENTATION_STATUS.md:15` 与 `FEATURES.md:287` 仍写「Linux 桌面唯一」 | ⚠️ **遗留**：需产品判断 Android 是否算正式目标平台 |
| 5 | 测试规模数字互不相同（Rust 130/144，Flutter 202/323/326/327） | ✅ 汇总行统一为实测值（Rust 148/12、Flutter 见最新章节）；各章历史快照保留为历史记录 |
| 6 | 翻译能力口径冲突：表格称「整本/随进度/手动」三种已完成，正文称后两种待后续 | ⚠️ **遗留**：需确认 RetainPDF 引擎收缩后到底支持哪几种 |
| 7 | 跨分支引用未标注：`:1195` 引「3.40」，本分支无该节 | ✅ 已加「对应改动在 android 分支」 |
| 8 | 版本号体系冲突：章节标题写 1.8.0/1.9.x，`pubspec` 为 1.0.0 | ⚠️ **遗留**：属历史章节标签，批量改会破坏记录 |
| 9 | `DEPENDENCIES.md` 列了已弃用的 `freezed` / `async-openai` / `super_clipboard` | ✅ 已按 `pubspec.yaml` 实际依赖重写，弃用项标明 |
| 10 | `BILINGUAL_READING_PLAN.md` 自述「已实施完毕」又「自研管线已移除」，指向 3 个已删文件 | ⚠️ **遗留**：建议整篇降级为历史归档并在开头加醒目标记 |
| 11 | `TECH_ROADMAP.md` 选型表以 async-openai 为 AI 客户端 | ✅ 已改为手写 reqwest SSE，保留旧方案作为「已弃用」记录 |
| 12 | `IMPLEMENTATION_STATUS.md` 96% 篇幅是按日期追加的日志（§3.1–§3.39），无按子系统索引 | ⚠️ **遗留**：建议在文首加「按子系统索引」表，别重排日志 |

**可信度排序建议**：代码 > `IMPLEMENTATION_STATUS.md` §3 各篇（描述具体缺陷与根因，信息量最高）> `README.md` > 其余文档。`FEATURES.md` 是需求规格而非实现状态（`:5` 明言），不要当完成度清单读。

---

## 14. 架构层面的真实风险（按影响排序）

1. **全局单例即吞吐天花板**：单 SQLite `Mutex<Connection>`（`connection.rs:24`）、单 `PDFIUM_LOCK`（`pdfium.rs:28`）、单文档 `DOC`（`:31`）、OCR 双模式各一把锁（`engine.rs:65`）。任一慢命令拖住其他命令。新增高开销命令务必 `spawn_blocking` 或走独立文档/线程。
2. **三处手写而非 crate 的实现**，换供应商/改契约时是主要工作面：① AI 流式客户端（`ai/openai.rs:7-14` 明述绕开 async-openai 的原因）；② 联网搜索另有一套协议（`ai/web_search.rs`）；③ OCR 输入桥 `translate/flat_ocr.rs:1-18` 产出的 JSON 是**外部引擎的契约**，改字段等于改外部程序接口。
3. **外部 Python sidecar**：翻译引擎两次 CLI 调用（`normalize-ocr` 与 `book`），进度靠 stdout JSONL 解析，取消需 kill 子进程并清 job 目录；API key 走环境变量 `RETAIN_TRANSLATION_API_KEY`（`translate/job.rs:8-10`）。
4. **模型/引擎文件不在仓库**：OCR 要求 `{data_dir}/models/{cls.onnx,ppocr_keys_v1.txt,high_precision/,fast/}`（`ocr/engine.rs:1-18`）；缺失表现为「模型未安装」错误而非崩溃。
5. **`panic = "abort"`**（`Cargo.toml:106`）与 `catch_unwind` 类恢复代码不兼容，也让 `main.dart` 必须在 `coreInit == false` 时止步。
6. **CI 刚建立（2026-11-26）**：`.github/workflows/ci.yml` 覆盖 `cargo test` 与 `flutter analyze`/`flutter test`，但尚未经 GitHub 实际运行验证（本地两条 job 的每条命令均已实测通过）；唯一集成测试仍硬编码本机数据，未纳入 CI。
7. **非默认 feature 组合无验证证据**：关 `ocr`/`ai` 靠桩编译，但仓库无 `--no-default-features` 构建记录（待核）。

---

## 15. 建议的上手路线

1. ~~先确认工作树~~ **已完成（2026-11-26）**：`cargo test` 148 通过 / 12 忽略、`flutter analyze` 零问题、`flutter test` 326 通过。§12 的识图修复已提交。
2. **跑通一次端到端改动**：用 §6 的五步加一个最简单的 Rust 命令（例如返回 schema 版本），走完 codegen → repository → UI，验证 FRB 管道与两套 cargo 目录的坑。
3. **优先修 §13 的文档不一致**，尤其 #3 schema 版本、#9 依赖清单、#1/#2 死链与分支名——这些会直接误导下一个接手的人。
4. **再动功能**。若要碰翻译，先读 `translate/flat_ocr.rs` 与 `translate/job.rs` 的外部契约；若要碰 AI，先读 `ai/openai.rs` 的手写 SSE 与 §12 的路由修复。
5. ~~补 CI~~ **已完成**：`.github/workflows/ci.yml` 两条 job（Rust `cargo test` / Flutter `analyze` + `test`），步骤与上述实测命令一一对应。后续可考虑给 `android` 分支加 `flutter build apk` 与 `cargo fmt --check`、`cargo clippy`。
