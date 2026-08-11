# 智阅（ZhiYue）

原生 AI 集成的本地阅读器：阅读 PDF（文字版 / 扫描版）与图片文件，选中文字即可翻译、解释、搜索；支持文本层与图像层标记；内置完全离线的本地 OCR 与多模态识图。

> **当前阶段：M0–M6 全部核心功能已完成。** 书库管理、PDF 管线、选区与文本层标记、AI 对话与识图、整页 OCR 与图像层标记、全文搜索均已实现，另有 OCR 精度增强（7.1.x 系列）。详见 [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)。

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
- **完全离线 OCR**：rapidocr-core（PP-OCRv4 det/cls/rec，ONNX Runtime 静态链接），高精度 + 快速双模式，模型随安装包内置（~210MB）。
- **AI 侧**：OpenAI 兼容协议（BYOK，可配 DeepSeek / Kimi / 通义等），流式对话（Markdown + LaTeX 渲染）+ 自由截图多模态识图。
- **目标平台**：Linux 桌面（Arch / Debian / Ubuntu / Fedora 等，详见 [`docs/LINUX_PACKAGES.md`](docs/LINUX_PACKAGES.md)）。
- **零参考**：完全重写，不迁移任何旧代码。

详见 [`docs/FEATURES.md`](docs/FEATURES.md)（需求）、[`docs/TECH_ROADMAP.md`](docs/TECH_ROADMAP.md)（技术路线）与 [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)（实施状态）。

## 目录结构

```
RBWA/
├── docs/                 # 需求与技术文档
│   ├── FEATURES.md               # 需求规格
│   ├── TECH_ROADMAP.md           # 技术路线
│   ├── IMPLEMENTATION_STATUS.md  # 实施状态与后续开发方向
│   ├── ARCHITECTURE.md           # 架构设计
│   ├── DEPENDENCIES.md           # 工具链依赖说明
│   ├── LINUX_PACKAGES.md         # Linux 分发包（deb/rpm/AppImage）
│   └── FLUTTER_UI_MIGRATION.md   # Flutter UI 迁移说明
├── scripts/              # 构建与安装脚本
│   ├── setup.sh                  # 工具链安装（cmake/ninja/Flutter/FRB codegen）
│   ├── download_ocr_models.sh    # 下载 OCR 模型（内置进安装包）
│   ├── fetch_pdfium.sh           # 获取 pdfium 二进制
│   └── build_packages.sh         # 构建 deb/rpm/AppImage（含 build_deb.sh）
├── rust/                 # Rust 核心 lib crate（rbwa_core）
│   ├── Cargo.toml
│   └── src/
│       ├── api.rs        # FRB 导出层（Flutter->Rust 唯一入口）
│       ├── models/       # 共享数据模型（跨 FFI）
│       ├── db/           # SQLite 连接 + schema + FTS5 索引
│       ├── pdf/          # PDF 渲染与文本提取（pdfium-render）
│       ├── ocr/          # OCR 引擎（rapidocr-core，懒加载）
│       ├── ai/           # AI 客户端（async-openai，流式）
│       ├── search/       # 全文搜索（FTS5 + jieba 分词）
│       ├── export.rs     # 标注导出（Markdown/JSON）
│       └── error.rs      # 统一错误类型
├── lib/                  # Flutter Dart 代码
│   ├── main.dart         # 启动初始化（窗口+FRB+SQLite）
│   ├── app.dart          # 根 widget（标题栏+主题+路由）
│   ├── router/           # go_router 配置
│   ├── core/             # 主题 / 常量 / 通用组件
│   ├── features/         # 功能模块（library/reader/annotation/ai/search/screenshot/settings/shell）
│   ├── data/             # 数据层（repositories，桥接 FRB）
│   ├── shared/           # 共享组件
│   └── src/rust/         # FRB 生成的 Dart 绑定（勿手改）
├── packaging/            # Linux 打包资源（desktop 文件 / 图标 / rpm spec）
├── assets/               # 图标、字体、占位图
├── dist/                 # 构建产物（deb/rpm/AppImage）
└── pubspec.yaml
```

## 快速开始

### 1. 安装工具链

```bash
sudo bash scripts/setup.sh
```

脚本会安装 cmake / ninja（pacman）、Flutter SDK、`flutter_rust_bridge_codegen`，并下载 pdfium 与 OCR 模型。详见 [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)。

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

### 3. 安装包

一键构建 deb / rpm / AppImage 分发包（内置 OCR 模型，约 250MB）：

```bash
bash scripts/build_packages.sh
```

安装与使用方式见 [`docs/LINUX_PACKAGES.md`](docs/LINUX_PACKAGES.md)。

### 4. 验证功能

应用启动后：

- 书库页：导入 PDF / 图片 → 网格展示 + 封面缩略图，支持收藏、删除、分类（拖拽归类）、检索
- 阅读器：单页 / 双滚动 / 双页三模式，缩放、翻页、进度恢复、侧栏（目录树、缩略图轨）
- 文字版 PDF：划词选区 → 高亮 / 下划线 / 删除线 / 笔记，标注侧栏 + Markdown/JSON 导出
- 扫描版 PDF / 图片：整页 OCR（高精度 / 快速双模式）→ 隐形文本层可选中；低置信度行标记 + 手动修正
- AI 侧栏：流式对话（提示词模板 / 自定义），自由截图 → 多模态识图
- 搜索：书库全局全文搜索（命中书 / 页 / 摘要 + 页内高亮）
- 数据：`~/.local/share/RBWA/rbwa.db`（SQLite WAL + FTS5 索引）

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 骨架 | 工程脚手架 + FRB 管道 + SQLite schema + UI 空壳 | ✅ 完成 |
| M1 书库 | 导入 / 网格 / 收藏 / 删除 / 分类（拖拽归类）/ 封面缩略图 / 无边框标题栏 / 主题持久化 | ✅ 完成 |
| M2 PDF 管线 | pdfium 渲染 → GPU 纹理 / 虚拟滚动 / 三视图模式 / 缩放 / 翻页 / 进度恢复 / 侧栏 | ✅ 完成 |
| M3 选区与文本层标记 | 字符盒精确选区 / 高亮 / 下划线 / 删除线 / 笔记 / 标注侧栏 / Markdown+JSON 导出 | ✅ 完成 |
| M4 AI 与识图 | 流式对话（Markdown + LaTeX）/ 提示词模板 / 历史持久化 / 自由截图 → 多模态识图 | ✅ 完成 |
| M5 整页 OCR 与图像层标记 | 扫描页自动检测 / 双模式整页扫描 / 隐形文本层 / 按页缓存 / 图片阅读 / 画笔 / 便签 / 图章 / 形状 / 拼合导出 | ✅ 完成 |
| M6 全文搜索 | FTS5 + jieba / 后台预构建 + 增量索引 / 失败终态标记 / 全局搜索跳转 / 页内高亮 | ✅ 完成 |
| 7.1.x OCR 精度 | 预处理增强 / 90° 自适应矫正 / 180° cls 矫正 / 置信度展示 / 手动修正 | ✅ 完成 |

各里程碑的详细实施记录见 [`docs/IMPLEMENTATION_STATUS.md`](docs/IMPLEMENTATION_STATUS.md)。

## 许可证

MIT OR Apache-2.0
