# Windows 11 构建指南

RBWA 的 Windows 移植准备工作已完成（`windows/` 平台骨架、Rust core + PDFium 集成、
平台代码适配）。**必须在 Windows 机器上构建**——Flutter 的 Windows 目标需要
Visual Studio 工具链，Linux 无法交叉编译。

## 前置要求（Windows 11 机器）

1. **Visual Studio 2022**（Community 版即可），工作负载勾选：
   - "使用 C++ 的桌面开发"（MSVC 编译器 + Windows SDK + CMake）
2. **Flutter SDK**（stable，≥3.44）：`flutter doctor` 确认 Windows 桌面可用
3. **Rust 工具链**：https://rustup.rs 安装（默认 MSVC target `x86_64-pc-windows-msvc`）
4. **Git**（可选，用于拉取代码）

## 构建步骤

```powershell
# 1. 拉取代码
git clone <你的仓库地址> RBWA
cd RBWA

# 2. 下载 PDFium（Windows 版，放到 rust/libpdfium/pdfium.dll）
powershell -ExecutionPolicy Bypass -File scripts/fetch_pdfium_windows.ps1

# 3. 下载 OCR 模型到打包目录（两套都打，随安装包分发；构建时 CMake 自动复制到 exe 旁）
powershell -ExecutionPolicy Bypass -File scripts\download_ocr_models.ps1 -All -Dir rust\models

# 4. 获取依赖
flutter pub get

# 5. 构建 release
flutter build windows --release

# 6. 产物位置
#    build\windows\x64\runner\Release\
#    里面的 rbwa.exe 就是主程序；rbwa_core.dll / pdfium.dll / models\ 已自动复制到同目录。
#    打包分发时把整个 Release 目录压缩即可（含 OCR 模型，用户无需再下载）。
```

> 注意：Rust 的 `cargo build` 由 CMake 自动触发（首次构建会编译整个 Rust 核心，
> 约 5-15 分钟；增量构建很快）。

## 运行时说明

| 项目 | 说明 |
|------|------|
| OCR 模型 | 与 exe 同目录的 `models\`（内置，无需下载）；开发运行（VS 直接跑）时若缺模型，Rust 回退到 `%APPDATA%\RBWA\models` |
| 截图保存目录 | `%USERPROFILE%\Pictures\RBWA`（已适配 Windows 的 USERPROFILE） |
| 数据库 | `%APPDATA%\RBWA\rbwa.db`（SQLite 单文件 + WAL） |
| PDFium | 与 exe 同目录的 `pdfium.dll`（已自动复制） |
| AI 配置 | 应用内设置页填写 API Key（BYOK） |

## 已知差异（Windows vs Linux）

- 标题栏：`window_manager` 插件在 Windows 上同样支持无边框 + 自定义标题栏
- 截图：基于 Flutter 的 `OffsetLayer.toImage`，与 Linux 同路径，无需系统 API
- 中文字体：Windows 自带微软雅黑，Flutter 自动 fallback，无需额外安装
- 性能：release 构建的 `rbwa_core.dll` 与 Linux 的 `.so` 同源（LTO + strip 已配置），
  内存/CPU 占用一致（常规阅读 1.0-1.5GB，OCR 扫描 4 线程）

## 如果构建报错

1. **`rbwa_core.dll` 找不到**：确认 Visual Studio 装了 "使用 C++ 的桌面开发"；
   CMake 的 VS 环境会自动把 MSVC 工具链暴露给 cargo
2. **`pdfium.dll` 缺失告警**：先跑 `scripts/fetch_pdfium_windows.ps1`
3. **Rust target 不对**：`rustup default stable-x86_64-pc-windows-msvc`
4. **flutter create 重新生成**：`flutter create --platforms=windows .` 只生成骨架，
   不会覆盖 `windows/CMakeLists.txt` 里加的 Rust 集成（若被覆盖，参考
   `linux/CMakeLists.txt` 的 Rust 段恢复）
