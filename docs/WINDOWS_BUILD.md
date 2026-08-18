# Windows 11 打包流程（完整版）

从零到可分发安装包的完整流程。**必须在 Windows 机器上构建**——Flutter 的
Windows 目标需要 Visual Studio 工具链，Linux 无法交叉编译。

## 一、环境准备（一次性）

| 依赖 | 要求 | 说明 |
|------|------|------|
| **Visual Studio 2022** | Community 版即可 | 工作负载勾选 **"使用 C++ 的桌面开发"**（MSVC 编译器 + Windows SDK + CMake，勾选后 VS 自动安装 CMake） |
| **Flutter SDK** | stable ≥3.44 | `flutter doctor` 确认 `Windows desktop` 显示 ✔ |
| **Rust 工具链** | 官方 rustup 安装 | 默认 MSVC target：`x86_64-pc-windows-msvc`（`rustup show` 确认） |
| **Git** | 任意版本 | 拉取代码 |
| **PowerShell** | 5.1+（Win10 1803+ 自带） | 运行下载脚本（内置 tar 解压） |
| **开发者模式** | 设置 → 开发者选项 | Flutter 插件构建需要符号链接权限，必须开启 |

检查命令：

```powershell
flutter doctor
rustup show          # 应显示 stable-x86_64-pc-windows-msvc
git --version
```

> 国内网络建议为 Flutter 配置镜像：`PUB_HOSTED_URL=https://pub.flutter-io.cn`
> `FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn`（系统环境变量）。
> Rust 同理：`RUSTUP_DIST_SERVER=https://rsproxy.cn`、`RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup`，
> 并在 `%USERPROFILE%\.cargo\config.toml` 配置 rsproxy sparse 源
> （`sparse+https://rsproxy.cn/index/`）加速 crates 下载。

## 二、拉取代码

```powershell
git clone <仓库地址> RBWA
cd RBWA
```

## 三、下载外部依赖（两个脚本）

```powershell
# 1. PDFium 动态库（约 7MB，落到 rust\libpdfium\pdfium.dll，脚本会校验 PE 头）
#    默认经国内加速代理（ghfast.top）拉取 GitHub Release，可用 -Mirror 覆盖
powershell -ExecutionPolicy Bypass -File scripts\fetch_pdfium_windows.ps1

# 2. OCR 模型两套（约 210MB，落到 rust\models\，构建时自动打进产物）
#    注意 -Dir rust\models —— 打包必须用这个参数，CMake 从这里安装模型
powershell -ExecutionPolicy Bypass -File scripts\download_ocr_models.ps1 -All -Dir rust\models
```

> 若仅本机开发（不打包分发），第 2 步可以省略 `-Dir`（模型下载到
> `%APPDATA%\RBWA\models`，Rust 回退路径加载）；打包分发必须用 `-Dir`。

### 开发自测补充（跑 `flutter test` 前）

widget 测试通过 FRB 加载 `rust/target/release/rbwa_core.dll`，因此需要先：

```powershell
cd rust; cargo build --release; cd ..
```

pdfium 由 Rust 核心按 cwd 回退到 `rust/libpdfium/` 自动定位，无需额外复制。

## 四、构建 release

```powershell
flutter pub get
flutter build windows --release
```

构建过程（CMake 自动完成，首次约 10-20 分钟）：

1. `cargo build`（debug + release 两个 profile，产物在 `build\windows\x64\runner\rust_target\`）
2. 编译 Flutter runner（C++）与引擎
3. 组装产物目录：把 `rbwa_core.dll`（按构建配置选 release）、`pdfium.dll`、
   `models\`、Flutter 引擎与资源全部复制到 exe 旁

产物目录：

```
build\windows\x64\runner\Release\
├── ZhiYue.exe                 # 主程序（BINARY_NAME = "ZhiYue"）
├── rbwa_core.dll             # Rust 核心（FRB：exe 目录 DLL 搜索优先）
├── pdfium.dll                # PDF 渲染库
├── flutter_windows.dll       # Flutter 引擎
├── screen_retriever_plugin.dll / window_manager_plugin.dll   # 插件
├── data\                     # flutter_assets + icudtl.dat
└── models\                   # OCR 模型（fast + high_precision + cls + 词表）
```

## 五、制作安装包

### 方式 A：绿色免安装版（最快）

```powershell
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath ZhiYue-0.1.0-win-x64.zip
```

用户解压后直接运行 `ZhiYue.exe`（首次运行时 Windows SmartScreen 可能提示，选择"仍要运行"）。

### 方式 B：Inno Setup 安装程序（推荐分发）

1. 安装 [Inno Setup](https://jrsoftware.org/isinfo.php)（免费）
2. 仓库已附示例脚本 `packaging\rbwa.iss`（AppName=智阅、装到 Program Files、
   创建开始菜单/桌面快捷方式、卸载入口齐全）
3. 编译：右键 `packaging\rbwa.iss` → Compile，产物 `dist\ZhiYue-0.1.0-win-x64-setup.exe`
   （安装向导为简体中文，语言文件 `packaging\ChineseSimplified.isl` 随脚本携带；
   安装向导与卸载图标使用 `packaging\icon\setup.ico`）

> 脚本要点：`Source: "..\build\windows\x64\runner\Release\*"` 整目录递归打包
> （含 `models\`），`ArchitecturesInstallIn64BitMode=x64` 强制 64 位安装。

### 依赖：VC++ 运行库

Flutter Windows 应用依赖 **Microsoft Visual C++ Redistributable（x64）**。
目标机器通常已有（系统更新自带）。稳妥做法：安装包附上
`vc_redist.x64.exe`（微软官网下载），或分发说明中提示：

```
如果打开提示 "VCRUNTIME140.dll 缺失"，请安装：
https://aka.ms/vs/17/release/vc_redist.x64.exe
```

## 六、目标机器验证清单

| 项目 | 操作 | 预期 |
|------|------|------|
| 启动 | 双击 ZhiYue.exe | 窗口标题"智阅"，进入书库 |
| 导入书籍 | 导入 PDF/图片 | 出现封面，双击可打开 |
| 文字版 PDF | 打开 | 文字可选择、可搜索 |
| OCR 扫描版 | 打开扫描书 → 整页 OCR | 直接可用（模型已内置，**无需下载**） |
| OCR 模式切换 | 设置页 → 识别模式 | 高精度/快速可切换 |
| AI 功能 | 设置页填 API Key → 翻译/解释/搜索 | 正常（BYOK） |
| 数据目录 | 查看 | `%APPDATA%\RBWA\`（数据库、文档副本） |

## 七、常见问题

| 现象 | 原因/解决 |
|------|-----------|
| `Building with plugins requires symlink support` | 未开启开发者模式（设置 → 开发者选项） |
| 构建报 `rbwa_core.dll` 找不到 | VS 未装"使用 C++ 的桌面开发"；或首次 cargo 编译未完成（等它跑完，约 5-15 分钟） |
| CMake 警告 `pdfium.dll not found` | 未运行 `fetch_pdfium_windows.ps1` |
| CMake 警告 `OCR models not found` | 未运行 `download_ocr_models.ps1 -All -Dir rust\models` |
| 运行提示缺 `VCRUNTIME140.dll` | 目标机装 VC++ Redistributable（见第五节） |
| Rust target 不对 | `rustup default stable-x86_64-pc-windows-msvc` |
| 用户机器 OCR 无反应 | 确认 `models\` 与 `ZhiYue.exe` 同目录（zip 解压时目录结构别拆散） |
| SmartScreen 拦截 | 未签名程序首次运行提示，选"仍要运行"；商业分发请购买代码签名证书 |

## 八、版本迭代

改代码后重新构建：

```powershell
flutter build windows --release        # 增量，约 1-3 分钟
# 改过 Rust 代码时 CMake 会自动重编 rbwa_core.dll（增量编译）
# 重新 Compile Inno Setup 脚本即可出新安装包
```

> 版本号统一维护：`pubspec.yaml`（Flutter）→ 打包时同步 `rbwa.iss` 的
> AppVersion 与产物文件名。

## 附：当前产物清单（0.1.0）

| 产物 | 大小（约） |
|------|-----------|
| 解压后目录（含模型） | ~300MB |
| zip 绿色版 | ~250MB |
| Inno Setup 安装包（lzma2） | ~250MB |
