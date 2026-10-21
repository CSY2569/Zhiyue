# Android 构建与安装

> 适用版本：Android v1（arm64）。规划与范围见 [`ANDROID_V1_PLAN.md`](ANDROID_V1_PLAN.md)，
> 实施记录见 [`IMPLEMENTATION_STATUS.md`](IMPLEMENTATION_STATUS.md) §3.23。

## 1. 系统要求

| 项 | 要求 |
|---|---|
| 设备 | **arm64-v8a**（Android 8.0 / API 26 及以上） |
| 磁盘 | 安装包约 286MB；安装后额外约 220MB（首启解压 OCR 模型） |
| 内存 | 建议 3GB+；高精度 OCR 单页峰值更高 |
| 网络 | 仅 AI 功能需要（用户自配 OpenAI 兼容端点）；**OCR 完全离线** |

> **不支持 x86_64**：ONNX Runtime 没有 Android x86_64 预编译产物，OCR 引擎
> 无法为该 ABI 链接。模拟器请选择 arm64 系统镜像。

## 2. 安装

1. 传输 `app-release.apk` 到设备（ADB、U 盘或下载均可）。
2. 允许「安装未知来源应用」。
3. 首次启动会显示「正在安装离线 OCR 模型」进度页，约 210MiB，一次性完成。
   空间不足时会明确提示；中断后下次启动自动重试。

## 3. 使用要点

- **导入**：书库页 → 导入 → 系统文件选择器（SAF），支持 PDF / PNG / JPG / WEBP / BMP / GIF / TIFF。
- **选词**：**长按**文字即选中整个词（有震动反馈），拖动扩展；选区两端有
  圆形手柄，可拖动精确调整起止位置（按词吸附）。**双击**文字也能选词。
  松手在屏幕**底部**弹出操作条（4×2：翻译 / 解释 / 搜索 / 复制 / 高亮 /
  下划线 / 删除线 / 笔记）。普通单指拖动用于滚动。
- **翻页手势**：点击屏幕**左侧 18%** 上一页、**右侧 18%** 下一页；
  点击**中间**显示 / 隐藏顶部与底部操作栏（沉浸阅读）。
- **全屏与常亮**：进入阅读器自动隐藏系统栏，阅读期间屏幕不会自动熄灭；
  退出阅读器后恢复。
- **从其他应用打开**：在文件管理器里点 PDF/图片选「智阅」，或在聊天/邮件里
  分享文件给智阅，应用会直接导入并打开书库。
- **阅读界面**：手机为「顶部条 + 底部操作栏」——底部依次是缩略图、目录、批注、
  AI、更多；缩放、对照阅读、识图、跳页在「更多」面板里。
- **缩放**：双指捏合，或双击在 1.2× / 2.0× 之间切换。
- **音量键**：手机端音量下 = 下一页，音量上 = 上一页（输入文字时不生效）。
- **对照阅读**：底部「更多」→「对照阅读」→ 手机上为「原文 / 译文」分段切换；
  首次打开某页时点「翻译本页」，之后翻页自动读缓存并预取后两页。
- **AI**：设置 → AI 设置，填写 base_url / API Key / 模型。对照阅读复用该配置与目标语言。
- **返回手势**：逐层返回——先关闭选区 / 侧栏 / AI 面板 / 对照，再退出阅读器回到书库；
  在书库时才会退到桌面。
- **书库手势**：轻点打开；**长按**弹出菜单（打开 / 收藏 / 分配到分类… / 多选 / 删除）。
  菜单里的「多选」进入批量模式：点选多本后可批量收藏、分类或删除。
  手机上没有拖拽归类，请在菜单里选择分类。左上角菜单按钮打开书库与分类抽屉，
  右上角「更多」里有全文搜索、主题与设置。
- **视图模式**：手机竖屏固定单页（双页在 360dp 宽下每页仅约 170dp，无法阅读）；
  横屏或平板可选择双页。

## 4. 从源码构建

### 4.1 一次性准备

```bash
# Rust Android target
rustup target add aarch64-linux-android
cargo install cargo-ndk

# Android SDK + NDK r28（示例路径）
export ANDROID_HOME=$HOME/Android/Sdk
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/28.2.13676358

# pdfium（arm64）
bash scripts/fetch_pdfium_android.sh

# 两套 OCR 模型进 assets（约 210MiB）
bash scripts/stage_android_models.sh
```

`android/local.properties` 需要有 `sdk.dir=<SDK 路径>`（`flutter build` 通常会自动写入）。

### 4.2 构建

```bash
# 调试包
bash scripts/build_android.sh

# 发布包（未配置签名时回退 debug 签名，仅测试用）
bash scripts/build_android.sh --release

# Play 用 AAB
bash scripts/build_android.sh --release --appbundle
```

产物：

```
build/app/outputs/flutter-apk/app-debug.apk
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/bundle/release/app-release.aab
```

### 4.3 签名

在 `android/key.properties`（已 gitignore）写入：

```properties
storeFile=/absolute/path/to/release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

## 5. 体积构成（release, arm64）

| 部分 | 约 |
|---|---|
| Flutter 引擎 + Dart AOT | 12MB |
| `librbwa_core.so`（含静态 ORT） | 32MB |
| `libpdfium.so` | 6.6MB |
| `libc++_shared.so` | 1.3MB |
| OCR 模型（高精度 + 快速 + cls + 字典） | 210MB |
| 其余（资源、Kotlin、签名等） | 约 20MB |
| **合计** | **约 286MB** |

## 6. 常见问题

**启动后书库是空的，导入按钮打开后看不到文件？**
SAF 只显示系统认为可选择的文件；某些文件管理器需要先授予目录权限。

**扫描页没有文字可选？**
该页尚未 OCR。阅读页会显示扫描提示，点击执行整页 OCR；结果会缓存。

**对照阅读提示未配置 AI？**
在「设置 → AI 设置」填写 OpenAI 兼容服务（地址 / Key / 文本模型）。

**高精度模式很慢？**
移动端默认使用快速模式；可在设置中切换。高精度适合对精度要求高的单页扫描。

**APK 装不上 / 提示 CPU 架构不兼容？**
只提供 arm64-v8a；x86_64 模拟器与 32 位设备不支持。

**升级后 OCR 模型会重新解压吗？**
仅当内置模型清单版本（`manifest.json.version`）变化时才重新安装。

## 7. 刷新率与流畅度

- **动态刷新率**：触摸 / 滚动时向屏幕请求最高档（上限 120Hz），静止约 1 秒后
  降到 30Hz。实际档位由面板支持的 mode 决定（90Hz 屏就停在 90Hz）；应用本身
  无法渲染超过面板刷新率。
- 如果某些机型静止时仍停在高刷，属于厂商的显示策略，应用侧无法强制。
- 阅读页的大位图在手机上按像素上限自动降采样（单页 ≤ 1200 万像素），所以
  4× 缩放不会因为显存/内存压力卡住。

## 8. 已知限制

- 对照阅读仅覆盖 PDF（含扫描页），图片书只支持 OCR + 划词 AI。
- 译文为文本列表，不保留原版式（桌面端的 RetainPDF 版式重排不在移动端）。
- 整本一次性翻译未提供；按页翻译 + 后两页预取。
- Play 分发需要把 `assets/models/` 改为 install-time asset pack（当前 APK 内嵌）。
