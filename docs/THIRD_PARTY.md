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

## 2. 按需下载的组件（不随包分发）

### BabelDOC 翻译引擎（可选，用户主动下载）

- 项目：<https://github.com/funstory-ai/BabelDOC>（含其发行包装 `pdf2zh-next`）
- 许可：**AGPL-3.0**（见上游 `LICENSE`）
- 集成方式：**独立程序**。应用在用户明确同意后，将引擎安装到应用数据目录
  （`{app_data_dir}/babeldoc`：uv 托管的 Python 环境 + `pdf2zh-next==2.9.0` 与
  资产），并通过**子进程**调用；Rust/Flutter 代码不链接、不嵌入其代码，
  应用本体不因该组件而受 AGPL 约束（GPL-3.0 与 AGPL-3.0 组合亦被 GPLv3 §13 允许）。
- 用户可随时在「设置 → 翻译引擎」卸载；卸载删除引擎环境与**由我们创建**的资产
  缓存（既有缓存不删除）。
- 该组件自带署名水印默认开启，本应用调用时显式关闭
  （`--watermark-output-mode=no_watermark`），并在设置界面标注其来源与许可。

> 说明：翻译所用的大模型服务（DeepL / OpenAI 兼容端点等）为用户自行配置的
> 第三方服务，不随应用分发，其条款由用户与服务方约定。

## 3. 维护约定

- 新增随包组件时，在本文件登记许可与版本。
- 新增「按需下载」的外部程序时，同样登记；如为 copyleft（GPL/AGPL），
  必须保持**独立进程**集成方式，不得链接进 `librbwa_core` 或以库形式嵌入。