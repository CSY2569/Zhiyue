# 智阅 · 架构图与核心时序图

> 基线代码：`feat/retain-engine`（RetainPDF 翻译栈版）。全部图为 Mermaid，可直接粘贴到
> 支持 Mermaid 的渲染器（GitHub / VS Code 预览 / mermaid.live）。
> 模块名与仓库路径对应：Dart 侧 `lib/features/*`、`lib/data/repositories/*`；
> Rust 侧 `rust/src/*`；桥接层 flutter_rust_bridge v2（FRB）。

## 0. 通信契约一览

| 通道 | 方向 | 承载内容 |
|---|---|---|
| FRB FFI 调用 | Dart → Rust | 全部业务调用：渲染、字符盒、DB 读写、OCR、AI 触发、翻译触发 |
| FRB StreamSink | Rust → Dart | `translate_book` 进度事件、`stream_chat` 流式 chunk、`install_engine` 事件 |
| 子进程 argv + stdout/stderr | Rust → RetainPDF pipeline | 两步 spec 文件路径；stdout JSONL 进度/产物事件；stderr `structured failure json:` |
| 环境变量 | Rust → pipeline | `RETAIN_TRANSLATION_API_KEY`（密钥不落盘）、`TYPST_BIN`、`TYPST_PACKAGE_PATH`、`OUTPUT_ROOT` |
| HTTP（流式） | Rust ai → LLM API | AI 动作（翻译/解释/搜索/对话/视觉）、内置搜索（Responses / Anthropic 两协议） |
| HTTP | Rust ai → 搜索端点 | 第三方（博查兼容）联网搜索 |
| HTTP | pipeline → LLM API | 翻译批次、公式/角色分类（key 由 env 注入，智阅 Rust 侧不代发） |
| SQLite（schema v9） | Rust 内部 | 书目、阅读进度、标注（含 `source` 窗格列）、AI 会话、OCR 缓存、FTS 索引 |

## 1. 架构图

```mermaid
flowchart TB
  subgraph UI["Flutter UI 层（lib/features）"]
    shell["shell<br/>窗口标题栏 / 导航"]
    library["library<br/>书架 / 分类 / 导入"]
    reader["reader<br/>页面滚动 / 缩放 / 大纲 / 侧栏"]
    bilingual["bilingual<br/>对照窗格 / 译文页渲染"]
    annotation["annotation<br/>划词 / 高亮层 / 浮动工具条 / 笔记"]
    ai["ai<br/>划词动作 / 侧栏多轮 / 识图"]
    searchui["search<br/>书内全文搜索页"]
    settings["settings<br/>AI / 翻译 / 搜索 / OCR 设置"]
    shot["screenshot<br/>区域截图识图覆层"]
  end

  subgraph STATE["状态层（Riverpod）"]
    prov["providers<br/>viewer / bitmap_cache / char_box_cache / selection / annotation<br/>ai / book_translation / translated_bitmap_cache / scan"]
    repos["repositories（lib/data/repositories）<br/>library / reader / ai / translation / search / settings"]
  end

  subgraph BRIDGE["flutter_rust_bridge v2"]
    ffi["FFI 调用（Dart → Rust）"]
    sink["StreamSink 事件流（Rust → Dart）<br/>翻译进度 / AI chunk / 引擎事件"]
  end

  subgraph CORE["Rust 核心 rbwa_core（rust/src）"]
    api["api.rs<br/>FFI 门面"]
    pdf["pdf<br/>pdfium 渲染 / 字符盒 / 译文页按宽渲染"]
    ocr["ocr<br/>rapidocr PP-OCRv4"]
    aimod["ai<br/>OpenAI 兼容客户端 / prompts / 内置与第三方搜索"]
    trans["translate<br/>job 两步运行器 / 引擎定位 / flat_ocr 输入桥"]
    searchmod["search<br/>FTS 全文索引"]
    db["db<br/>SQLite schema v9（annotations.source）"]
    export["export<br/>标注 Markdown / JSON"]
  end

  subgraph EXT["外部进程与网络服务"]
    pipe["RetainPDF pipeline 子进程<br/>随包 CPython 3.11：normalize-ocr → book"]
    typst["Typst 0.15.1 + @preview 包<br/>排版与公式渲染"]
    llm["LLM API<br/>OpenAI 兼容 / Anthropic Messages"]
    bocha["博查兼容搜索端点"]
  end

  subgraph FS["本地文件系统（app 数据目录）"]
    docsf["documents/ 书目副本"]
    jobsf["retain_jobs/ 翻译任务目录"]
    outf["retain_output/ 每书 LLM 缓存"]
    trf["translated/ 译文 PDF + manifest"]
    ocrf["page_ocr OCR 缓存"]
    dbf["zhiyue.db"]
  end

  UI -->|"read / watch"| prov
  prov --> repos
  repos -->|"FFI"| ffi
  ffi --> api
  api -.->|"事件"| sink
  sink -.-> prov
  api --> pdf
  api --> ocr
  api --> aimod
  api --> trans
  api --> searchmod
  api --> db
  api --> export
  shot -->|"截图 PNG 识图"| ai
  trans -->|"子进程 stdio：spec + JSONL 进度"| pipe
  pipe --> typst
  pipe -->|"翻译 / 分类请求（env 注入 key）"| llm
  aimod -->|"HTTP 流式（AI 动作 / 内置搜索）"| llm
  aimod -->|"HTTP（第三方搜索）"| bocha
  pdf --> docsf
  pdf --> trf
  ocr --> ocrf
  trans --> jobsf
  trans --> outf
  trans --> trf
  db --> dbf
  searchmod --> dbf
```

要点：

- **两个 LLM 调用方**：AI 动作与内置搜索由 Rust `ai` 模块直连 LLM；**翻译请求由 pipeline 子进程自己发**（key 经 env 注入，spec 只写 `credential_ref`），智阅 Rust 侧只解析其 stdout 进度。
- **pipeline 是独立进程**（随包 CPython，无 venv），崩溃/取消只影响子进程树；PyMuPDF（AGPL）因此被隔离在进程边界外。
- **译文与原文是两份 PDF**：对照窗格按页宽 tier 渲染 `translated/{book_id}/translated.pdf`，标注用 `annotations.source` 区分窗格（schema v9）。

## 2. 核心时序图

### 2.1 书籍导入与全文索引

```mermaid
sequenceDiagram
    actor U as 用户
    participant LP as library_page
    participant LR as LibraryRepository
    participant API as rust api.rs
    participant PDF as pdfium
    participant DB as SQLite
    participant SP as search_providers

    U->>LP: 导入 PDF（选择文件）
    LP->>LR: importBook(path)
    LR->>API: FRB import_book
    API->>API: 扩展名校验 / 按 original_path 去重
    API->>API: 拷贝到 documents/uuid.pdf
    API->>PDF: 打开书目（页数 / 封面）
    API->>DB: 插入 books 行
    API-->>LR: ImportResult
    LR-->>LP: Book
    LP-->>U: 书架刷新
    Note over SP,DB: 进入搜索页时按书检查索引状态
    SP->>API: indexStatus；status=missing 时 ensureBookIndex
    API->>PDF: 逐页抽取文本
    API->>DB: 写入 FTS 全文索引
```

### 2.2 页面渲染与文本层（含 OCR 回退、缩放 tier）

```mermaid
sequenceDiagram
    participant PS as pdf_page_scroll（_PageItem）
    participant BC as BitmapCache（LRU 20，zoom 0.5 步进 tier）
    participant RR as ReaderRepository
    participant API as rust api.rs
    participant PDF as pdfium
    participant CBC as CharBoxCache（LRU 8）
    participant OH as ocr_helpers / scan_provider
    participant RO as rapidocr PP-OCRv4

    PS->>BC: getOrFetch(bookId, page, zoom, dpr)
    alt tier 命中
        BC-->>PS: ui.Image 直接返回
    else 未命中（含 in-flight 去重）
        BC->>RR: renderPage(bookId, page, tier, dpr)
        RR->>API: FRB render_page
        API->>PDF: 按 tier × dpr 渲染 RGBA
        PDF-->>API: rgba / width / height
        API-->>RR: PageRenderResult
        RR-->>BC: 字节
        BC->>BC: decodeRgbaImage → ui.Image 入 LRU（淘汰即 dispose）
        BC-->>PS: ui.Image
    end
    PS->>PS: RawImage 绘制 + HighlightLayer / SelectionLayer 叠层
    PS->>CBC: getOrFetch(bookId, page)（划词 / 命中测试数据）
    CBC->>API: FRB extract_text（pdfium 字符盒）
    alt 有原生文本层
        API-->>CBC: CharBox[]
    else 扫描页 / 图片书
        CBC->>OH: cachedOcrAnyMode（读 page_ocr 缓存）
        alt 无缓存
            OH->>API: pageHasText=false 后 scanPage → FRB scan_page
            API->>RO: OCR 推理（high_precision）
            RO-->>API: 行盒
            API->>API: 写 page_ocr 缓存 + 隐形文本层
        end
        OH-->>CBC: 整行 CharBox[]
    end
    Note over PS,BC: 缩放改变 → quantizeZoom 换 tier → 走未命中分支按更高分辨率重渲
```

### 2.3 整本翻译（RetainPDF 两步管线）

```mermaid
sequenceDiagram
    actor U as 用户
    participant TP as translated_pane（对照窗格）
    participant BTC as BookTranslationController
    participant TR as TranslationRepository
    participant API as rust api.rs
    participant JOB as translate::job
    participant FO as translate::flat_ocr
    participant ENG as pipeline 子进程（CPython）
    participant LLM as LLM API
    participant TYP as Typst 0.15
    participant TBC as TranslatedBitmapCache（LRU 12，宽度 tier）

    U->>TP: 点击「整本翻译」
    TP->>BTC: translate()
    BTC->>TR: translateBook(bookId)
    TR->>API: FRB translate_book（StreamSink）
    API->>JOB: translate_book(book_id, on_event)
    JOB->>JOB: mark_translating + 建 retain_jobs/id/ 任务目录
    JOB->>FO: build_flat_document（文字层聚类 / OCR 行）
    FO-->>JOB: generic_flat_ocr payload.json
    JOB->>ENG: 步骤1 normalize-ocr --spec（纯本地）
    ENG-->>JOB: document.v1.json（stdout JSONL 进度）
    JOB->>ENG: 步骤2 book --spec（env: RETAIN_TRANSLATION_API_KEY, OUTPUT_ROOT）
    loop 翻译批次 + 排版
        ENG->>LLM: 批次翻译 / 公式与角色分类（命中 retain_output 缓存则免请求）
        LLM-->>ENG: 译文
        ENG->>TYP: Typst 编译（cmarker / mitex 公式）
        ENG-->>JOB: JSONL：stage observation / artifact_published
        JOB-->>BTC: StreamSink BookTranslateEvent（phase / detail）
        BTC-->>TP: 进度 UI（翻译中 / 排版输出 / 批次 n）
    end
    ENG-->>JOB: rendered/name-translated.pdf
    JOB->>JOB: 拷到 translated/id/translated.pdf + manifest；清理任务目录
    JOB-->>BTC: 事件 done（失败则 stderr structured failure → error）
    BTC->>BTC: refresh + translationRevision++
    TP->>TBC: translatedPageImageProvider（bookId, page, targetWidthPx）
    TBC->>API: FRB render_translated_page（按窗格宽度 tier 渲染）
    API-->>TBC: RGBA → ui.Image
    TBC-->>TP: 对照窗格按页展示
    Note over BTC,API: 取消：cancel_book_translation 杀子进程树并清理任务目录
```

### 2.4 划词与双窗格标注（schema v9 source）

```mermaid
sequenceDiagram
    actor U as 用户
    participant SL as SelectionLayer（原文 / 译文窗格各一）
    participant SEL as selectionProvider
    participant FT as FloatingToolbar
    participant AP as annotationProvider
    participant RR as ReaderRepository
    participant API as rust api.rs
    participant DB as SQLite annotations（source 列）
    participant HL as HighlightLayer（双窗格）

    U->>SL: 在译文窗格拖选
    SL->>SL: 归一化坐标 → 行 / 字命中（lineIndexAt）
    SL->>SEL: updateSelection（仅本窗格 source 的预览 rects）
    SEL-->>SL: 预览高亮（原文窗格不受影响）
    U->>SL: 抬手
    SL->>SEL: commitSelection（工具条全局锚点）
    SEL-->>FT: 弹出（翻译 / 解释 / 高亮 / 下划线 / 删除线 / 笔记…）
    U->>FT: 点「高亮」
    FT->>AP: create(kind, rects, pane = sel.source)
    AP->>RR: createAnnotation(..., source)
    RR->>API: FRB create_annotation
    API->>DB: insert annotations（source='translated'）
    API-->>AP: ok
    AP->>HL: invalidate annotationsProvider
    HL->>HL: 按 source 过滤绘制；笔记栏显示「译」徽标
    Note over SL,FT: 译文窗格划词跳过 OCR 行编辑；原文窗格流程同构（source='original'）
```

### 2.5 AI 动作与联网搜索（内置双协议 / 第三方）

```mermaid
sequenceDiagram
    actor U as 用户
    participant FT as FloatingToolbar / AI 侧栏
    participant AIP as aiProvider（AiNotifier）
    participant AIR as AiRepository
    participant API as rust api.rs
    participant PROM as ai::prompts
    participant WEB as 第三方搜索端点（博查兼容）
    participant LLM as LLM API
    participant DB as SQLite ai_threads / ai_messages

    U->>FT: 翻译 / 解释 / 搜索 / 追问
    FT->>AIP: startAction(action, text, …)
    AIP->>AIR: createAiThread / appendAiMessage（用户消息）
    AIR->>DB: 落库
    AIP->>AIR: streamChat(action, history, …)
    AIR->>API: FRB stream_chat（StreamSink<String>）
    API->>PROM: 角色模板 + 动作 system prompt（查询包 <text> 防注入）
    alt 搜索 且 联网开 且 内置搜索
        API->>LLM: 按设置协议：{base}/responses + web_search 工具，或 {base}/anthropic/v1/messages + web_search_20250305
        LLM-->>API: 带引用的流式作答
    else 搜索 且 第三方搜索
        API->>WEB: POST 搜索端点（搜索专用 Key）
        WEB-->>API: 检索结果
        API->>LLM: 结果注入提示词后 stream_chat
        LLM-->>API: 流式作答（仅引用结果链接）
    else 其他动作 / 搜索失败降级
        API->>LLM: stream_chat（失败时注明原因、基于知识作答）
        LLM-->>API: 流式 chunk
    end
    loop StreamSink chunk
        API-->>AIP: 事件串（delta / 引用 / done / error）
        AIP-->>FT: 增量渲染 UI
    end
    AIP->>AIR: appendAiMessage（assistant）
    AIR->>DB: 落库
```
