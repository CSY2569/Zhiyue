# RBWA 开发依赖说明

本文件记录 RBWA 项目（Flutter Desktop + Rust + flutter_rust_bridge v2）所需的全部开发依赖、版本锁定与安装方式。

> 一键安装：`sudo bash scripts/setup.sh`（幂等，可重复执行）。以下为手动安装参考与版本约束说明。

## 目标平台

- **基准平台**：Linux（CachyOS / Arch 系）
- 保持 Windows / macOS 可移植性（`docs/TECH_ROADMAP.md` §10.6）

---

## 1. 系统依赖（Linux）

Flutter Linux 桌面构建链需要以下系统库/工具。本机已有：clang 22 / LLVM 22 / pkg-config / gtk3 / glib2 / zenity。

| 依赖 | 版本要求 | 安装命令（Arch 系） | 用途 |
|---|---|---|---|
| clang | ≥ 14 | `pacman -S clang` | FRB / 原生 crate 编译 |
| cmake | ≥ 3.16 | `pacman -S cmake` | 部分 Rust crate 与 Flutter Linux 插件构建 |
| ninja | ≥ 1.10 | `pacman -S ninja` | Flutter Linux 构建后端 |
| pkg-config | ≥ 0.29 | `pacman -S pkgconf` | 原生库探测 |
| gtk3 | 3.x | `pacman -S gtk3` | Flutter Linux gnome embedder |
| glib2 | 2.x | `pacman -S glib2` | GTK 依赖 |
| zenity | 任意 | `pacman -S zenity` | `file_picker` 文件对话框（已具备） |

> Debian/Ubuntu 等价：`apt install clang cmake ninja-build pkg-config libgtk-3-dev libglib2.0-dev zenity`

## 2. Rust 工具链

| 组件 | 版本 | 说明 |
|---|---|---|
| rustc / cargo | ≥ 1.70（本机 1.97.1） | stable 通道，目标 `x86_64-unknown-linux-gnu` |
| rustup | 最新 | 工具链管理 |

安装：https://rustup.rs

> 当前无需额外 target。若后续需要 Android 构建再 `rustup target add aarch64-linux-android ...`。

## 3. Flutter SDK

- 通道：**stable**
- 安装方式：clone `https://github.com/flutter/flutter.git`（stable 分支）到 `$HOME/flutter`，并将 `$HOME/flutter/bin` 加入 `PATH`。
- 首次运行 `flutter` 会自动下载 Dart SDK。

`scripts/setup.sh` 会自动完成 clone 并把 PATH 写入 `~/.zshrc`。

## 4. flutter_rust_bridge v2

| 组件 | 版本 | 安装方式 |
|---|---|---|
| `flutter_rust_bridge_codegen`（Rust 侧） | **2.12.0** | `cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked` |
| `flutter_rust_bridge`（Dart pub 包） | **2.12.0** | 写入 `pubspec.yaml`，`flutter pub get` 安装 |
| `flutter_rust_bridge`（Rust crate） | **2.12.0** | 写入 `rust/Cargo.toml` |

> ⚠️ 三者版本必须严格一致，否则 codegen 产物与运行时不匹配。`setup.sh` 安装的是 Rust 侧 codegen 工具；Dart 包与 Rust crate 版本由工程清单文件锁定。

最新稳定版查询：
- Rust crate / codegen：https://crates.io/crates/flutter_rust_bridge_codegen
- Dart 包：https://pub.dev/packages/flutter_rust_bridge

## 5. 项目核心 crate 依赖（Rust 侧，骨架阶段声明不深度调用）

| crate | 版本 | 用途 | 对应里程碑 |
|---|---|---|---|
| `flutter_rust_bridge` | 2.12 | FFI 类型安全绑定 + Stream | 全程 |
| `pdfium-render` | 0.9 | PDF 渲染 + 文本提取 + 字符盒 | M2 |
| `rapidocr-core` | 最新 | 本地 OCR（PP-OCRv4 det/cls/rec） | M5 |
| `async-openai` | 最新 | AI 流式 chat + 多模态（BYOK） | M4 |
| `rusqlite` | 0.32+（bundled, WAL） | SQLite + FTS5 | M1 |
| `jieba-rs` | 最新 | 中文分词（FTS5） | M6 |
| `image` | 0.25 | 缩略图 / 图像处理 | M2 |
| `tokio` | 1 | 异步运行时 | 全程 |
| `anyhow` | 1 | 错误处理 | 全程 |
| `thiserror` | 1 | 错误类型定义 | 全程 |
| `tracing` / `tracing-subscriber` | 0.1 / 0.3 | 结构化日志 | 全程 |
| `reqwest` | 0.12 | AI 备选 / 模型下载 | M4/M5 |

> 骨架阶段以上依赖仅在 `rust/Cargo.toml` 声明，确保 `cargo check` 通过；真实集成在对应里程碑。版本以实际 `Cargo.toml` 为准。

## 6. Flutter 侧依赖（pubspec.yaml，骨架阶段）

| 包 | 用途 |
|---|---|
| `flutter_rust_bridge` | Rust 绑定 |
| `flutter_riverpod` / `riverpod_annotation` | 状态管理 |
| `go_router` | 路由 |
| `freezed` / `freezed_annotation` / `json_serializable` / `build_runner` | 不可变数据模型 |
| `window_manager` | 无边框窗口 |
| `file_picker` | 文件对话框 |
| `super_clipboard` | 剪贴板 |
| `flutter_markdown` | Markdown（GFM）渲染 |
| `flutter_math_fork` | LaTeX 公式渲染 |
| `shared_preferences` | 配置持久化（骨架阶段过渡用） |

## 7. 运行时资源（不在骨架阶段下载）

| 资源 | 说明 | 引入时机 |
|---|---|---|
| libpdfium.so | pdfium 动态库，随包分发 | M2 |
| PP-OCRv4 模型 | det/cls/rec + 字符表；快速模式 ~5MB / 高精度 ~90MB；按需下载 + 完整性校验 | M5 |
| jieba 词典 | ~5MB，可换精简版 | M6 |

## 8. 验收自检

安装完成后应满足：

```bash
flutter --version          # stable 通道
flutter doctor             # Linux toolchain 无红线
cargo --version            # 1.70+
flutter_rust_bridge_codegen --version   # 2.12.0
clang --version && cmake --version && ninja --version
```
