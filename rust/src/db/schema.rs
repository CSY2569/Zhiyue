//! SQLite schema definition for RBWA.
//!
//! Implements the 10 data structures listed in `docs/FEATURES.md` §9.1:
//!   books, reading_progress, annotations, page_ocr_cache,
//!   page_text_index, ai_history, settings, categories, image_annotations.
//!
//! Conventions (per FEATURES §9.2.1):
//!   - WAL journal mode, foreign keys ON, cascade cleanup.
//!   - Normalized coordinates stored as REAL in [0.0, 1.0].
//!   - Timestamps as ISO-8601 TEXT (chrono).
//!
//! This module only *defines* SQL strings; [`crate::db::connection`] executes
//! them and manages the schema version table.

/// Schema version; bump on any breaking migration. Stored in `schema_version`.
pub const SCHEMA_VERSION: u32 = 3;

/// Indexes for per-book AI conversation windows (v3, FEATURES 6.5.4).
///
/// Created by [`crate::db::connection::migrate`] (idempotent), NOT from
/// `SCHEMA_SQL`: on a v2 database the `book_id` column only exists after the
/// ALTER in the migration chain, and `execute_batch(SCHEMA_SQL)` runs before
/// it -- an index referencing a missing column would fail init. The unique
/// partial index enforces one window per book at the DB level (null book_id =
/// the no-book window, unlimited).
pub fn ensure_ai_window_indexes(conn: &rusqlite::Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_ai_threads_book ON ai_threads(book_id);
         CREATE UNIQUE INDEX IF NOT EXISTS uq_ai_threads_book
             ON ai_threads(book_id) WHERE book_id IS NOT NULL;",
    )
}

/// All CREATE statements, in dependency order (referenced tables first).
///
/// `IF NOT EXISTS` keeps this idempotent across reruns.
pub const SCHEMA_SQL: &str = r#"
-- ===========================================================================
-- 1. categories  (FEATURES 9.1.9)
--    Custom book classifications. books.category_id -> categories.id.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS categories (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ===========================================================================
-- 2. books  (FEATURES 9.1.1)
--    Library entry. title / path / type / cover / pages / favorite /
--    category / last_opened. Duplicated by original path (de-dup on import).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS books (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    title         TEXT NOT NULL,
    original_path TEXT NOT NULL UNIQUE,        -- de-dup key (FEATURES 2.1)
    stored_path   TEXT NOT NULL,               -- copy under app data dir
    file_type     TEXT NOT NULL,               -- 'pdf' | 'image'
    page_count    INTEGER NOT NULL DEFAULT 0,
    cover_path    TEXT,                        -- thumbnail path, nullable
    favorite      INTEGER NOT NULL DEFAULT 0,  -- 0/1 boolean
    category_id   INTEGER,
    last_opened_at TEXT,                       -- ISO-8601, nullable until first open
    imported_at   TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (category_id) REFERENCES categories(id)
        ON DELETE SET NULL                     -- deleting a category unclassifies books
);
CREATE INDEX IF NOT EXISTS idx_books_last_opened ON books(last_opened_at DESC);
CREATE INDEX IF NOT EXISTS idx_books_category    ON books(category_id);
CREATE INDEX IF NOT EXISTS idx_books_file_type   ON books(file_type);

-- ===========================================================================
-- 3. reading_progress  (FEATURES 9.1.2 / 3.3.4)
--    Page number + zoom per book. Cascades on book delete.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS reading_progress (
    book_id   INTEGER PRIMARY KEY,
    page      INTEGER NOT NULL DEFAULT 1,
    zoom      REAL NOT NULL DEFAULT 1.2,       -- default 120% (FEATURES 3.2.1)
    view_mode TEXT NOT NULL DEFAULT 'single',  -- 'single' | 'double_scroll' | 'double_page'
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

-- ===========================================================================
-- 4. annotations  (FEATURES 9.1.3 / §4 text-layer marks)
--    Text-layer annotations: highlight / underline / strikethrough / note.
--    Coordinates normalized per page (FEATURES 4.3.4).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS annotations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id     INTEGER NOT NULL,
    page        INTEGER NOT NULL,
    kind        TEXT NOT NULL,                 -- 'highlight'|'underline'|'strikethrough'|'note'
    text        TEXT,                          -- selected text the mark was created from
    content     TEXT,                          -- note text (nullable for mark-only)
    rects       TEXT NOT NULL,                 -- JSON array of normalized rects [{x,y,w,h}, ...]
    color       TEXT,                          -- hex color string
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_annotations_book_page ON annotations(book_id, page);

-- ===========================================================================
-- 5. image_annotations  (FEATURES 9.1.10 / §5 image-layer marks)
--    Image-layer marks: brush / shape / sticky / stamp. Stored SEPARATELY
--    from text annotations, decoupled from OCR (FEATURES 5.5).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS image_annotations (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    book_id     INTEGER NOT NULL,
    page        INTEGER NOT NULL,
    kind        TEXT NOT NULL,                 -- 'brush'|'shape'|'sticky'|'stamp'
    -- Normalized position + transform (FEATURES 5.5: type / normalized pos / style)
    x           REAL NOT NULL,                 -- normalized center x
    y           REAL NOT NULL,                 -- normalized center y
    w           REAL,                          -- normalized width (nullable for freehand)
    h           REAL,                          -- normalized height (nullable for freehand)
    rotation    REAL NOT NULL DEFAULT 0.0,
    -- Kind-specific payload as JSON: path points for brush, text for sticky,
    -- image bytes ref for stamp, geometry for shape.
    payload     TEXT NOT NULL,                 -- JSON
    style       TEXT NOT NULL,                 -- JSON: color / strokeWidth / fill / fontSize
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_image_ann_book_page ON image_annotations(book_id, page);

-- ===========================================================================
-- 6. page_ocr_cache  (FEATURES 9.1.5 / 7.1.4)
--    Full-page OCR result cache, keyed by (book_id, page). Cascades on book delete.
-- ===========================================================================
CREATE TABLE IF NOT EXISTS page_ocr_cache (
    book_id      INTEGER NOT NULL,
    page         INTEGER NOT NULL,
    ocr_mode     TEXT NOT NULL,                -- 'high_precision' | 'fast'
    result_json  TEXT NOT NULL,                -- serialized OcrResult (lines + rects + confidence)
    created_at   TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (book_id, page, ocr_mode),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

-- ===========================================================================
-- 8. page_text_index  (FEATURES 9.1.6 / §3.5)
--    Per-page text source for full-text search. Text-PDF uses pdfjs text,
--    scanned uses OCR result. FTS5 virtual table for jieba-tokenized search.
-- ===========================================================================
-- Metadata table mapping (book_id, page) -> source + raw text.
CREATE TABLE IF NOT EXISTS page_text_index (
    book_id   INTEGER NOT NULL,
    page      INTEGER NOT NULL,
    source    TEXT NOT NULL,                   -- 'pdf' | 'ocr'
    raw_text  TEXT NOT NULL,
    indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (book_id, page),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

-- FTS5 full-text index over page_text_index.raw_text.
-- content_source links to the metadata table so deletes cascade into FTS.
CREATE VIRTUAL TABLE IF NOT EXISTS page_text_fts USING fts5(
    raw_text,
    content='page_text_index',
    content_rowid='rowid',
    tokenize='unicode61'                       -- jieba applied at index time in search subsystem
);

-- ===========================================================================
-- 9. ai_history  (FEATURES 9.1.7 / 6.5.4)
--    Persisted AI conversation windows + messages. One window per book:
--    every AI exchange inside a book shares its window (book_id); null
--    book_id = the no-book window. No FK to books -- deleting a book keeps
--    its conversation (per-window deletion is a user choice in the AI panel).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS ai_threads (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    title       TEXT NOT NULL,                 -- book title snapshot / "未打开书籍"
    action_type TEXT NOT NULL,                 -- 'translate'|'explain'|'search'|'chat'|'vision' (latest action)
    book_id     INTEGER,                       -- owning book; null = no-book window
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_ai_threads_updated ON ai_threads(updated_at DESC);

CREATE TABLE IF NOT EXISTS ai_messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    thread_id   INTEGER NOT NULL,
    role        TEXT NOT NULL,                 -- 'user' | 'assistant' | 'system'
    content     TEXT NOT NULL,                 -- markdown
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (thread_id) REFERENCES ai_threads(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS ai_messages_thread ON ai_messages(thread_id, created_at);

-- ===========================================================================
-- 10. settings  (FEATURES 9.1.8 / §6.1, §8.2)
--     Key-value config store. API keys live ONLY here, never logged (§9.2.2).
-- ===========================================================================
CREATE TABLE IF NOT EXISTS settings (
    key         TEXT PRIMARY KEY,
    value       TEXT NOT NULL,                 -- JSON-encoded value
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ===========================================================================
-- schema_version: migration gate. Checked on every init_core().
-- ===========================================================================
CREATE TABLE IF NOT EXISTS schema_version (
    version    INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
);
"#;

/// PRAGMAs applied right after opening a connection (FEATURES 9.2.1).
pub const PRAGMAS: &[&str] = &[
    "PRAGMA journal_mode = WAL;",
    "PRAGMA foreign_keys = ON;",
    "PRAGMA synchronous = NORMAL;",
];
