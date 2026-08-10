# 智阅（ZhiYue）

原生 AI 集成的本地阅读器：阅读 PDF（文字版 / 扫描版）与图片文件，选中文字即可翻译、解释、搜索；支持文本层与图像层标记；内置本地 OCR 与多模态 OCR。

> **当前阶段：整体骨架（M0）。** 仅包含工程脚手架、FRB 管道、SQLite schema、UI 空壳与启动初始化。业务功能在各里程碑逐步实现。

## 架构

```
┌────────────────────────────────────────────────┐
│ Flutter Desktop（UI 层，Dart）                  │
│  书库  阅读区  标记层  侧边栏  AI 面板  设置      │
│  状态管理：Riverpod   模型：freezed             │
└───────────────────┬────────────────────────────┘
                    │ flutter_rust_bridge v2（类型安全 FFI）
┌───────────────────┴────────────────────────────┐
│ Rust 核心层（无 UI，全部重活）                    │
│  PDF（pdfium-render）  OCR（rapidocr-core）      │
│  AI（async-openai）    SQLite + FTS5 + jieba    │
│  数据模型 / 命令接口（FRB 导出）                 │
└────────────────────────────────────────────────┘
```

- **分工原则**：所有重活与数据在 Rust 侧（PDF 渲染、OCR、AI 网络、数据库、搜索索引）；Flutter 只做绘制与交互。
- **零参考**：完全重写，不迁移任何旧代码。

详见 [`docs/FEATURES.md`](docs/FEATURES.md)（需求）与 [`docs/TECH_ROADMAP.md`](docs/TECH_ROADMAP.md)（技术路线）。

## 目录结构

```
RBWA/
├── docs/                 # 需求与技术文档
│   ├── FEATURES.md
│   ├── TECH_ROADMAP.md
│   ├── DEPENDENCIES.md
│   └── ARCHITECTURE.md
├── scripts/
│   └── setup.sh          # 工具链安装脚本（cmake/ninja/Flutter/FRB codegen）
├── rust/                 # Rust 核心 lib crate（rbwa_core）
│   ├── Cargo.toml
│   └── src/
│       ├── api.rs        # FRB 导出层（Flutter->Rust 唯一入口）
│       ├── models/       # 共享数据模型（跨 FFI）
│       ├── db/           # SQLite 连接 + schema（10 张表）
│       ├── pdf/          # PDF 服务 trait（M2 实现）
│       ├── ocr/          # OCR 引擎 trait（M5 实现）
│       ├── ai/           # AI 客户端 trait（M4 实现）
│       ├── search/       # 全文搜索 trait（M6 实现）
│       └── error.rs      # 统一错误类型
├── lib/                  # Flutter Dart 代码
│   ├── main.dart         # 启动初始化（窗口+FRB+SQLite）
│   ├── app.dart          # 根 widget（标题栏+主题+路由）
│   ├── router/           # go_router 配置
│   ├── core/theme/       # 亮/暗主题 + 持久化
│   ├── features/         # 功能模块（library/reader/ai/ocr/settings/shell）
│   ├── data/             # 数据层（repositories，桥接 FRB）
│   └── src/rust/         # FRB 生成的 Dart 绑定（勿手改）
├── linux/                # Flutter Linux 平台配置（含 Rust .so 构建集成）
├── assets/               # 图标、字体、占位图
└── pubspec.yaml
```

## 快速开始

### 1. 安装工具链

```bash
sudo bash scripts/setup.sh
```

脚本会安装 cmake / ninja（pacman）、Flutter SDK、`flutter_rust_bridge_codegen`。详见 [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)。

### 2. 构建与运行

```bash
# 重新生成 FRB 绑定（修改 rust/src/api.rs 后执行）
flutter_rust_bridge_codegen generate

# 构建（debug）-- 会自动编译 Rust crate 并打包 .so
flutter build linux --debug

# 运行
./build/linux/x64/debug/bundle/rbwa

# 或直接热重载开发
flutter run -d linux
```

### 3. 验证骨架

应用启动后：
- 自定义无边框标题栏显示，可拖拽、最小化/最大化/关闭
- 书库页显示空状态引导
- 主题可在书库页右上角或设置页切换（持久化到 SQLite）
- 路由可在书库 ↔ 阅读器 ↔ 设置间切换（空壳）
- `~/.local/share/RBWA/rbwa.db` 已创建，含全部表（WAL 模式）

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **M0 骨架** | 工程脚手架 + FRB + SQLite schema + UI 空壳 | ✅ 已完成 |
| M1 书库 | 导入/网格/收藏/删除/分类/检索 | ✅ 已完成 |
| M2 PDF 管线 | pdfium 渲染 + 虚拟滚动 + 三模式 + 侧栏 | ✅ 已完成 |
| M3 选区与文本标记 | 字符盒选区 + 高亮/下划线/笔记 + 标注侧栏/导出 | ✅ 已完成 |
| M4 AI 与区域 OCR | async-openai 流式 + 结果卡片/AI 侧栏 + 多模态区域 OCR | ✅ 当前 |
| M5 图像层标记 + 整页 OCR | 画笔/便签/图章 + rapidocr | 待实现 |
| M6 全文搜索 + 打磨 | FTS5 + jieba + 性能调优 | 待实现 |

## 许可证

MIT OR Apache-2.0
