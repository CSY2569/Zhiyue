# RBWA 架构说明

本文档定义模块职责边界、FRB 调用约定、数据流与后续各里程碑的接入点。实现任何新功能前请先读此文档，确保「低耦合、高内聚」。

## 1. 分层与职责边界

```
┌─────────────────────────────────────────────────────────┐
│  Flutter UI 层 (lib/)                                    │
│  features/*  router  core/theme  shared/widgets          │
│  职责：绘制、交互、本地状态（Riverpod）                   │
│  禁止：直接读写文件系统 / 数据库 / 网络                    │
├─────────────────────────────────────────────────────────┤
│  数据层 (lib/data/)                                      │
│  repositories/*  models/*                                │
│  职责：把 UI 需求翻译成 FRB 调用，把 Rust 返回值转成       │
│        Dart 友好的不可变模型（freezed）                    │
│  禁止：包含业务逻辑（逻辑在 Rust 侧）                      │
├─────────────────────────────────────────────────────────┤
│  ════════ flutter_rust_bridge v2 FFI 边界 ════════       │
│  仅 rust/src/api.rs 的 pub 函数可跨边界                    │
├─────────────────────────────────────────────────────────┤
│  Rust 核心层 (rust/src/)                                  │
│  api  models  db  pdf  ocr  ai  search  error             │
│  职责：全部重活（渲染/OCR/AI/DB/搜索）与数据持久化         │
└─────────────────────────────────────────────────────────┘
```

**核心约束**：
- Flutter 侧**只能**通过 `lib/data/repositories/` 调用 `lib/src/rust/api.dart`（FRB 生成），不直接 import `lib/src/rust/*`（`main.dart` 的 `RustLib.init()` 除外）。
- Rust 侧**只有** `api.rs` 里的 `pub fn` 会被 FRB 导出；其它模块的 `pub` 项不会跨边界。
- 跨边界的类型必须在 `rust/src/models/` 定义（FRB 可导出的 plain struct/enum）。

## 2. FRB 调用约定

### 2.1 命令函数风格

`api.rs` 里的命令函数遵循：
- 简单同步操作直接返回值（如 `ping() -> String`）。
- 涉及 IO/重活的用 `async`（FRB 会生成 `Future`）。骨架阶段未用，M2+ 大量使用。
- 流式输出（AI 流式、OCR 进度）用 `StreamSink<T>` 参数，FRB 生成 `Stream<T>`。
- 错误：避免返回 `Result<T, AppError>`（FRB 会把它当不透明类型）。骨架阶段用「返回值哨兵」（如 `i32` 0/1，`Option<String>`）。M1+ 引入正规的 `Result` 处理时，需配合 `frb` 的 `Result` 支持或显式错误字段。

### 2.2 重新生成绑定

修改 `rust/src/api.rs` 或 `rust/src/models/` 后必须重新生成：

```bash
flutter_rust_bridge_codegen generate
```

生成的文件（勿手改）：
- Rust 侧：`rust/src/frb_generated.rs`
- Dart 侧：`lib/src/rust/api.dart`、`lib/src/rust/frb_generated*.dart`

### 2.3 类型映射

| Rust | Dart |
|---|---|
| `String` | `String` |
| `i64`/`i32`/`f64`/`bool` | `int`/`int`/`double`/`bool` |
| `Option<T>` | `T?` |
| `Vec<T>` | `List<T>` |
| `struct` (plain) | class（带构造器、==、hashCode） |
| `enum` (unit) | enum / sealed class（`dart_enums_style: true`） |
| trait 对象 / 泛型 | `#[frb(opaque)]` → 不透明句柄 |

## 3. 数据流示例

**读取书库（M1 将实现）**：
```
LibraryPage (UI)
  → LibraryRepository.listBooks()  (lib/data/repositories/)
    → rust.api.listBooks()         (lib/src/rust/api.dart, FRB 生成)
      → api::list_books()          (rust/src/api.rs)
        → db::repository::books::list()  (rust/src/db/repository/books.rs)
      → Vec<Book>                  (rust/src/models/book.rs)
    ← List<Book> (Dart)
  ← Riverpod state 更新 → UI 重绘
```

## 4. Rust 模块职责

| 模块 | 职责 | 接入里程碑 |
|---|---|---|
| `api` | FFI 命令聚合层，唯一跨边界入口 | 全程 |
| `models` | 共享数据类型（Book/Annotation/OcrResult/AiMessage…） | 各里程碑按需扩展 |
| `db` | SQLite 连接、schema（已建 10 表）、迁移、repository | M1+ |
| `db/schema.rs` | **已完成**全部建表 DDL（WAL + 外键级联） | M0 |
| `db/connection.rs` | **已完成**全局 `Mutex<Connection>` + init | M0 |
| `pdf` | `PdfService` trait：render/extract_text/char_boxes/outline | M2 |
| `ocr` | `OcrEngine` trait：run_page/load/cancel | M5（区域 OCR 在 M4） |
| `ai` | `AiClient` trait：stream_chat/vision/cancel | M4 |
| `search` | `SearchIndex` trait：index_page/search | M6 |
| `error` | `AppError` 统一错误枚举 | 全程 |

## 5. 后续里程碑接入点

实现新功能时，按以下位置填入代码：

### M1 书库
- Rust: 在 `rust/src/db/repository/` 新建 `books.rs`、`categories.rs`，实现 CRUD（trait + rusqlite 实现）。
- Rust: 在 `api.rs` 新增 `list_books()` / `import_book(path)` / `delete_book(id)` 等命令，委托给 repository。
- Dart: 在 `lib/data/repositories/library_repository.dart` 包装 FRB 调用。
- Dart: 在 `lib/features/library/` 实现 `LibraryGrid`、导入流程（`file_picker`）、分类侧栏（`Draggable`）。

### M2 PDF 管线
- Rust: 在 `rust/src/pdf/` 实现 `PdfiumService`（`pdfium-render`），启用 `pdf` feature。
- Rust: 在 `api.rs` 新增 `open_book`/`render_page`/`extract_text` 命令（返回 `Uint8List` 位图）。
- Dart: 在 `lib/features/reader/` 实现 `PdfViewport`（虚拟滚动 + 纹理显示）。

### M3 选区与文本标记
- Rust: `api.rs` 新增标注 CRUD（`annotations` 表）。
- Dart: `lib/features/annotation/` 实现字符盒命中、工具条、`CustomPaint` 绘制高亮/下划线。

### M4 AI 与区域 OCR
- Rust: `rust/src/ai/` 实现 `OpenAiClient`（`async-openai`），启用 `ai` feature。
- Rust: `api.rs` 新增 `stream_chat`（用 `StreamSink<String>`）、`vision`。
- Dart: `lib/features/ai/` 实现结果卡片、侧边栏线程、`flutter_markdown` 流式渲染。

### M5 图像层标记 + 整页 OCR
- Rust: `rust/src/ocr/` 实现 `RapidOcrEngine`，引入 `rapidocr-core`。
- Dart: `lib/features/ocr/` + 图像层标记（`CustomPainter` 矢量层）。

### M6 全文搜索
- Rust: `rust/src/search/` 实现 `Fts5Index`（jieba 分词 + FTS5），启用 `search` feature。
- Dart: `lib/features/library/` 或 `lib/features/reader/` 加搜索 UI。

## 6. 错误处理约定

- Rust 侧：子系统内部用 `AppResult<T>`（`Result<T, AppError>`）。`AppError` 用 `thiserror`，从各 crate 错误 `From` 转换。
- 跨 FFI：避免直接返回 `Result`（FRB 限制）。用哨兵值或带 `error: Option<String>` 字段的结构体（如 `InitResult`）。
- 日志：Rust 侧用 `tracing`（`RUST_LOG=info` 调级别），输出到 stderr。

## 7. 构建集成

Rust crate 通过 `linux/CMakeLists.txt` 集成到 Flutter Linux 构建：
- `add_custom_command` 调 `cargo build`，输出到 `build/.../rust_target/`。
- `install(FILES)` 把 `librbwa_core.so` 复制到 `bundle/lib/`。
- 运行时靠 RPATH `$ORIGIN/lib` 加载（`linux/CMakeLists.txt` 已设）。
- Debug 构建用 cargo `debug/` 子目录，Release 用 `release/`。

修改 `rust/src/` 后重新 `flutter build` 会自动触发 cargo（依赖了 `*.rs`）。
