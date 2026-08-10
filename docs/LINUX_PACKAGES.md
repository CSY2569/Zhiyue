# Linux 分发包（deb / rpm / AppImage）

构建产物在 `dist/` 目录：

| 包 | 大小 | 适用发行版 |
|----|------|-----------|
| `rbwa_<ver>_amd64.deb` | ~250M | Debian / Ubuntu / Linux Mint 等 |
| `rbwa-<ver>-1.x86_64.rpm` | ~250M | Fedora / RHEL / Rocky / OpenSUSE 等 |
| `rbwa-x86_64.AppImage` | ~250M | 任意发行版（免安装） |

体积含内置 OCR 模型（高精度 + 快速两套，~210MB）。

## 安装

### Debian / Ubuntu（.deb）

```bash
sudo apt install ./rbwa_0.1.0_amd64.deb
# 依赖自动安装（libgtk-3-0、libglib2.0-0 等，apt 会处理）
```

卸载：`sudo apt remove rbwa`

### Fedora / RHEL（.rpm）

```bash
sudo dnf install ./rbwa-0.1.0-1.x86_64.rpm
# 依赖自动安装（gtk3、glib2 等，dnf 会处理）
```

卸载：`sudo dnf remove rbwa`

### 任意发行版（AppImage）

```bash
chmod +x rbwa-x86_64.AppImage
./rbwa-x86_64.AppImage          # 直接运行
# 或放到 ~/Applications 并加入 PATH
```

无需安装、无依赖问题（AppImage 自带运行时，系统只需有 FUSE 或可挂载）。

## 依赖声明

deb / rpm 包已声明完整运行依赖，包管理器自动安装：

| 依赖 | 用途 |
|------|------|
| GTK3 / glib2 / pango / cairo / harfbuzz | Flutter 图形栈 |
| libX11 / libxkbcommon / freetype / fontconfig | 窗口与字体 |
| libc6 / libstdc++ | 基础运行库 |
| libicu / libsqlite3 / libxml2 / libpng | 文本与数据 |
| dbus | 系统总线 |
| fonts-noto-cjk（debian 名）/ google-noto-sans-cjk-fonts（rpm 名） | 中文字体（Flutter 渲染中文必需） |

AppImage 不声明依赖——它使用宿主系统的 GTK 等库（主流桌面发行版均已预装）。

## OCR 模型（已内置）

PP-OCRv4 两套模型（高精度 server ~200MB + 快速 mobile ~16MB）**已随包内置**，安装后直接可用，无需任何下载。安装位置：`/usr/lib/rbwa/models/`（AppImage 在应用目录内 `models/`）。

> 仅开发环境（未打包运行时）需要 `scripts/download_ocr_models.sh` 手动下载到 `~/.local/share/RBWA/models/`。

## 数据位置

| 数据 | 路径 |
|------|------|
| 数据库（书库/标注/AI 历史） | `~/.local/share/RBWA/rbwa.db` |
| 截图保存 | `~/Pictures/RBWA/` |
| 导入的文档副本 | `~/.local/share/RBWA/documents/` |

卸载包**不会**删除这些数据（用户数据保留）。

## 重新构建

```bash
bash scripts/build_packages.sh          # 一次构建三种包
bash scripts/build_deb.sh               # 只构建 deb
rpmbuild -bb packaging/rbwa.spec        # 只构建 rpm（需先把 bundle 放 SOURCES）
```

## 最低配置

- CPU：x86_64，建议 4 核+（OCR 扫描用 4 线程）
- 内存：建议 8GB（常规阅读 1.0-1.5GB，OCR 时 +200MB）
- 系统：Ubuntu 20.04+ / Fedora 34+ / 任意主流桌面发行版
