# 第三方组件与许可

本文件登记随包分发与按需下载的第三方组件及其许可，供分发合规审阅。
（开发工具链依赖见 [`DEPENDENCIES.md`](DEPENDENCIES.md)。）

## 1. 随应用分发的组件

| 组件 | 用途 | 许可 |
|---|---|---|
| 本项目（智阅 / ZhiYue / RBWA） | 应用本体 | GPL-3.0（见仓库根 `LICENSE`） |
| pdfium（`libpdfium.so`） | PDF 渲染 / 文本抽取 | BSD-3-Clause（Chromium 项目） |
| Flutter / Dart 运行时 | UI 框架 | BSD-3-Clause |
| PP-OCRv4 模型（rapidocr / PaddleOCR 系） | 本地 OCR | Apache-2.0 |
| rapidocr-core、jieba-rs 等 Rust 依赖 | OCR / 中文分词 | 见 `rust/Cargo.lock` 各包声明（MIT / Apache-2.0 为主） |
| **RetainPDF 管线引擎**（`retainpdf/`，含其依赖） | 整本翻译 + 版式重排 | 见 §2.1 |

## 2. 随包内置的翻译引擎（RetainPDF）

### 2.1 retainpdf-pipeline（上游源码 vendored，MIT）

- 项目：<https://github.com/wxyhgk/retain-pdf>（管线包 `retainpdf-pipeline` 4.2.6）
- 许可：**MIT**（见 `third_party/retainpdf/LICENSE`；vendored 记录见
  `third_party/retainpdf/PIN.md`）
- 集成方式：**独立进程**。应用通过 `python -c ...main()` 以子进程调用
  `retainpdf-pipeline` 的 `normalize-ocr` / `book` 两个命令（引擎布局与运行
  参数见 `rust/src/translate/engine.rs`），Rust/Flutter 代码不链接其 Python 代码。
- 引擎目录随安装包分发（`<exe_dir>/retainpdf`），设置界面标注来源与许可；
  应用内不提供卸载（引擎是安装包的一部分）。

### 2.2 引擎内置的第三方依赖（均随包分发，由 `scripts/build_retain_engine.sh` 组装）

| 组件 | 用途 | 许可 | 说明 |
|---|---|---|---|
| CPython 3.11（python-build-standalone） | 管线运行时 | PSF-2.0 | uv 托管的独立解释器 |
| PyMuPDF (`fitz`) | 源 PDF 读写 / 页面分析 | **AGPL-3.0** | 上游管线依赖；经**独立进程**调用，应用本体不因该组件受 AGPL 约束（GPLv3 §13） |
| pikepdf | PDF 内容流处理 | MPL-2.0 | |
| Pillow | 图像处理 | MIT-CMU | |
| requests / urllib3 | HTTP | Apache-2.0 / MIT | |
| Typst（`bin/typst` 0.15.1） | 译文排版编译 | Apache-2.0 | 上游 CI 钉死版本 |
| Typst `@preview` 包：cmarker 0.1.10 / mitex 0.2.7 | 文档/公式渲染 | MIT / Apache-2.0 | 目录 `retainpdf/typst-packages/` |
| Source Han Serif SC（思源宋体） | 译文正文字体 | OFL-1.1 | 取自上游 `resources/fonts`，OFL 文本随附 |

> 说明：翻译所用的大模型服务（OpenAI 兼容端点）为用户自行配置的第三方服务，
> 不随应用分发，其条款由用户与服务方约定。本引擎版本不含水印功能。

## 3. 维护约定

- 新增随包组件时，在本文件登记许可与版本。
- 新增「按需下载」的外部程序时，同样登记；如为 copyleft（GPL/AGPL），
  必须保持**独立进程**集成方式，不得链接进 `librbwa_core` 或以库形式嵌入。
  当前 RetainPDF 引擎即以此方式集成（其 PyMuPDF 依赖为 AGPL-3.0）。
- 升级 vendored 管线 = 整体替换 `third_party/retainpdf/` 并更新 `PIN.md`
  （记录新提交哈希与版本），同时复核本节依赖版本。