//! Flutter -> Rust command surface (flutter_rust_bridge v2).
//!
//! This module is the single aggregation point for all functions exported to
//! Dart. Each subsystem exposes higher-level commands here; the Dart side
//! never calls into `pdf` / `ai` / `db` directly. This keeps the FFI boundary
//! narrow and the architecture loosely coupled (TECH_ROADMAP §1:
//! "命令调用 -> Rust").
//!
//! Core exports:
//!   - `init_core()`      : open SQLite, apply schema, set up logging.
//!   - `app_version()`    : return crate version for the About UI.
//!   - `get_setting` / `set_setting`: persisted KV settings.
//!
//! Subsystem commands (book import, render, annotations, ai) are added per
//! milestone, each delegating to the relevant service.

use std::path::Path;
use std::sync::OnceLock;

use crate::db;
use crate::db::repository::progress as progress_repo;
use crate::db::repository::{book as book_repo, category as category_repo};
use crate::db::repository::book::NewBook;
use crate::error::{AppError, AppResult};
use crate::models::book::{Book, BookType, Category};
use crate::models::progress::{ReadingProgress, ViewMode};
use crate::pdf;
use crate::pdf::types::{CharBox, OutlineEntry, PageBitmap};

/// Global flag set once `init_core` succeeds. Cheap to read from Dart-side
/// polling (skeleton only; M1+ replaces with a proper state machine).
static INITIALIZED: OnceLock<bool> = OnceLock::new();

/// Crate version, surfaced in the About / settings UI.
pub fn app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Result of core initialization, returned to Flutter.
pub struct InitResult {
    pub ok: bool,
    /// Resolved database file path (for display / diagnostics).
    pub db_path: String,
    /// Schema version applied.
    pub schema_version: u32,
    /// Human-readable error if initialization failed.
    pub error: Option<String>,
}

/// Initialize the Rust core. Called exactly once on app startup, before any
/// other command. Opens SQLite, applies the schema (idempotent), and sets up
/// tracing. Safe to call again; returns the cached result.
pub fn init_core() -> InitResult {
    if INITIALIZED.get().is_some() {
        return InitResult {
            ok: true,
            db_path: db::db_path()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default(),
            schema_version: db::schema::SCHEMA_VERSION,
            error: None,
        };
    }

    match try_init() {
        Ok(path) => {
            let _ = INITIALIZED.set(true);
            InitResult {
                ok: true,
                db_path: path.to_string_lossy().to_string(),
                schema_version: db::schema::SCHEMA_VERSION,
                error: None,
            }
        }
        Err(e) => InitResult {
            ok: false,
            db_path: String::new(),
            schema_version: 0,
            error: Some(e.to_string()),
        },
    }
}

fn try_init() -> AppResult<std::path::PathBuf> {
    try_init_at(&db::db_path()?)
}

/// Shared init logic for a given database path.
fn try_init_at(path: &std::path::Path) -> AppResult<std::path::PathBuf> {
    // Structured logging to stderr; tune via RUST_LOG.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();

    tracing::info!(version = app_version(), "initializing RBWA core");

    let path = db::init_database_at(path)?;
    tracing::info!(?path, "database ready");
    Ok(path)
}

/// Test hook: initialize the core against an explicit database path so
/// integration tests never touch the user's real data (all test writes --
/// books, annotations, AI config -- land in the isolated DB). Mirrors
/// [init_core] otherwise. Not used in production.
pub fn init_core_with_db_path(db_path: String) -> InitResult {
    match try_init_at(std::path::Path::new(&db_path)) {
        Ok(path) => {
            let _ = INITIALIZED.set(true);
            InitResult {
                ok: true,
                db_path: path.to_string_lossy().to_string(),
                schema_version: db::schema::SCHEMA_VERSION,
                error: None,
            }
        }
        Err(e) => InitResult {
            ok: false,
            db_path: String::new(),
            schema_version: 0,
            error: Some(e.to_string()),
        },
    }
}

/// Read a setting value by key (skeleton: direct KV read).
/// Returns empty string if the key is absent. Real subsystem repos wrap
/// this in M1; for the skeleton an empty string sentinel is sufficient.
///
/// # Panics
/// Panics if called before `init_core()` (programming error).
pub fn get_setting(key: String) -> Option<String> {
    let conn = db::db();
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        rusqlite::params![key],
        |row| row.get::<_, String>(0),
    )
    .ok()
}

/// Write a setting value by key (upsert). Skeleton helper for theme etc.
/// Returns 1 on success, 0 on failure.
///
/// # Panics
/// Panics if called before `init_core()` (programming error).
pub fn set_setting(key: String, value: String) -> i32 {
    let conn = db::db();
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now'))
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        rusqlite::params![key, value],
    )
    .map(|_| 1)
    .unwrap_or(0)
}

// =============================================================================
// M1 -- Library (书库) commands (FEATURES §2)
// =============================================================================
//
// All commands here delegate to `db::repository::*` for SQL, keeping the FFI
// surface thin. Errors crossing the boundary are converted to sentinel values
// (empty vec, `Option::None`, `i32` 0/1) per ARCHITECTURE §6: we never return
// `Result` over FRB. The file-copy step in `import_book` happens *outside* the
// DB lock so a slow disk does not stall other queries.

/// Outcome of importing one file (FEATURES 2.1).
pub struct ImportResult {
    /// The imported (or already-existing) book record. `None` on failure.
    pub book: Option<Book>,
    /// `true` if the original path was already in the library; the existing
    /// record is returned unchanged (de-dup by `original_path`).
    pub already_existed: bool,
    /// Human-readable error message when import failed; `None` on success.
    pub error: Option<String>,
}

impl ImportResult {
    fn ok(book: Book, existed: bool) -> Self {
        Self {
            book: Some(book),
            already_existed: existed,
            error: None,
        }
    }

    fn err(msg: impl Into<String>) -> Self {
        Self {
            book: None,
            already_existed: false,
            error: Some(msg.into()),
        }
    }
}

/// List every book in the library, most-recently-opened first (FEATURES 2.2/2.3).
/// Returns an empty vec on error (the UI shows the empty-state guide).
pub fn list_books() -> Vec<Book> {
    let conn = db::db();
    book_repo::list(&conn).unwrap_or_default()
}

/// Fetch a single book by id. Returns `None` if not found (FEATURES 2.3:
/// the reader needs the book's stored_path and page_count to open it).
pub fn get_book(id: i64) -> Option<Book> {
    let conn = db::db();
    book_repo::get(&conn, id).ok().flatten()
}

/// Import a single file into the library (FEATURES 2.1).
///
/// Steps: validate path → infer type → de-dup by `original_path` → copy file
/// into `~/.local/share/RBWA/documents/` → insert row. The DB lock is released
/// during the file copy so concurrent reads are not blocked.
///
/// Async: pdfium open + cover rendering are heavyweight; running them off the
/// UI thread (FRB executes `async fn` on a worker) keeps the UI responsive.
pub async fn import_book(path: String) -> ImportResult {
    match import_book_inner(&path).await {
        Ok(r) => r,
        Err(e) => ImportResult::err(e.to_string()),
    }
}

async fn import_book_inner(original_path: &str) -> AppResult<ImportResult> {
    let src = Path::new(original_path);

    // 1. Validate the path exists and is a file.
    if !src.is_file() {
        return Ok(ImportResult::err(format!(
            "file not found: {original_path}"
        )));
    }

    // 2. Infer the document type from the extension.
    let ext = src
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("");
    let file_type = match BookType::from_extension(ext) {
        Some(t) => t,
        None => {
            return Ok(ImportResult::err(format!(
                "unsupported file type: .{ext}"
            )));
        }
    };

    // 3. De-dup by original_path (FEATURES 2.1). Drop the lock before file IO.
    {
        let conn = db::db();
        if let Some(existing) = book_repo::find_by_original_path(&conn, original_path)? {
            return Ok(ImportResult::ok(existing, true));
        }
    }

    // 4. Copy the file into the app data dir under `documents/`.
    let documents_dir = db::app_data_dir()?.join("documents");
    std::fs::create_dir_all(&documents_dir)?;

    let stored_name = format!("{}.{}", uuid::Uuid::new_v4(), ext);
    let stored_path = documents_dir.join(&stored_name);
    std::fs::copy(src, &stored_path)?;
    let stored_path_str = stored_path.to_string_lossy().to_string();

    // 5. Derive title from the filename stem; set page count / cover.
    let title = src
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("untitled")
        .to_string();
    let page_count: i64 = match file_type {
        BookType::Pdf => 0, // updated below after pdfium open
        BookType::Image => 1,
    };
    // For images the file itself is the cover; PDF covers are rendered below.
    let cover_path: Option<String> = match file_type {
        BookType::Image => Some(stored_path_str.clone()),
        BookType::Pdf => None,
    };

    // 6. Insert the book row.
    let new_book = NewBook {
        title,
        original_path: original_path.to_string(),
        stored_path: stored_path_str.clone(),
        file_type,
        page_count,
        cover_path,
    };
    let book = {
        let conn = db::db();
        book_repo::insert(&conn, &new_book)?
    };

    // 7. For PDFs, open with pdfium to get the real page count and render a
    //    cover thumbnail. Failures here are non-fatal (the book is still
    //    imported; the user can open it and the reader will retry).
    if file_type == BookType::Pdf {
        match pdf::open(&stored_path_str) {
            Ok(count) => {
                let covers_dir = db::app_data_dir()
                    .map(|d| d.join("covers"))
                    .ok();
                let cover_path_str = covers_dir.as_ref().and_then(|dir| {
                    std::fs::create_dir_all(dir).ok()?;
                    let p = dir.join(format!("{}.png", book.id));
                    // Render page 0 as a ~400px-wide thumbnail and encode to PNG.
                    match pdf::thumbnail(0, 400) {
                        Ok(bmp) => {
                            save_rgba_as_png(&bmp, &p).ok()?;
                            Some(p.to_string_lossy().to_string())
                        }
                        Err(e) => {
                            tracing::warn!(error = %e, "cover render failed");
                            None
                        }
                    }
                });
                let conn = db::db();
                let _ = book_repo::update_page_count(&conn, book.id, count);
                let _ = book_repo::update_cover(&conn, book.id, cover_path_str.clone());
                tracing::info!(id = book.id, count, "pdf metadata updated");
            }
            Err(e) => {
                tracing::warn!(error = %e, "pdf open failed during import; page count stays 0");
            }
        }
        pdf::close();
    }

    // Re-fetch the book so the returned record reflects any metadata updates
    // (page_count, cover_path) applied above.
    let book = {
        let conn = db::db();
        book_repo::get(&conn, book.id)?
            .ok_or_else(|| AppError::Internal("book vanished after insert".into()))?
    };

    tracing::info!(id = book.id, ?file_type, "book imported");
    Ok(ImportResult::ok(book, false))
}

/// Delete a book by id (FEATURES 2.4). Removes the row (cascading to progress,
/// annotations, OCR cache, text index via FK) and deletes the stored file
/// and cover thumbnail. Returns 1 on success, 0 if the book was not found.
pub fn delete_book(id: i64) -> i32 {
    // Fetch the stored_path + cover_path first so we can clean up files, then
    // delete the DB row (cascade handles child tables).
    let (stored_path, cover_path) = {
        let conn = db::db();
        match book_repo::get(&conn, id) {
            Ok(Some(book)) => {
                let removed = book_repo::delete(&conn, id).unwrap_or(false);
                if removed {
                    (Some(book.stored_path), book.cover_path)
                } else {
                    (None, None)
                }
            }
            _ => (None, None),
        }
    };

    if let Some(path) = stored_path {
        // Best-effort file cleanup; a missing file is not an error.
        let _ = std::fs::remove_file(&path);
        if let Some(cover) = cover_path {
            let _ = std::fs::remove_file(&cover);
        }
        1
    } else {
        0
    }
}

/// Toggle the favorite flag on a book (FEATURES 2.5). Returns the updated
/// book, or `None` if the id was not found.
pub fn toggle_favorite(id: i64) -> Option<Book> {
    let conn = db::db();
    let book = book_repo::get(&conn, id).ok().flatten()?;
    let new_fav = !book.favorite;
    book_repo::set_favorite(&conn, id, new_fav)
        .ok()
        .flatten()
}

/// Record that a book was opened (FEATURES 2.3: recent-open sort).
/// Returns 1 on success, 0 if the book was not found.
pub fn touch_last_opened(id: i64) -> i32 {
    let conn = db::db();
    match book_repo::touch_last_opened(&conn, id) {
        Ok(()) => {
            // touch_last_opened is a no-op if the row is absent; verify.
            if book_repo::get(&conn, id).ok().flatten().is_some() {
                1
            } else {
                0
            }
        }
        Err(_) => 0,
    }
}

/// Assign a book to a category, or unclassify it (`category_id = None`)
/// (FEATURES 2.8). Returns 1 on success, 0 if the book was not found.
pub fn assign_category(book_id: i64, category_id: Option<i64>) -> i32 {
    let conn = db::db();
    match book_repo::set_category(&conn, book_id, category_id) {
        Ok(()) => {
            if book_repo::get(&conn, book_id).ok().flatten().is_some() {
                1
            } else {
                0
            }
        }
        Err(_) => 0,
    }
}

// -----------------------------------------------------------------------------
// Category commands (FEATURES 2.8)
// -----------------------------------------------------------------------------

/// List all categories (FEATURES 2.8). Empty vec on error.
pub fn list_categories() -> Vec<Category> {
    let conn = db::db();
    category_repo::list(&conn).unwrap_or_default()
}

/// Create a new category (FEATURES 2.8). Returns the new category, or `None`
/// if the name is already taken or creation failed.
pub fn create_category(name: String) -> Option<Category> {
    let conn = db::db();
    category_repo::create(&conn, &name).ok()
}

/// Rename a category (FEATURES 2.8). Returns 1 on success, 0 if not found or
/// the new name collides.
pub fn rename_category(id: i64, name: String) -> i32 {
    let conn = db::db();
    category_repo::rename(&conn, id, &name)
        .map(|ok| ok as i32)
        .unwrap_or(0)
}

/// Delete a category (FEATURES 2.8). Books referencing it fall back to
/// unclassified (`category_id` set to NULL via the FK rule). Returns 1 on
/// success, 0 if not found.
pub fn delete_category(id: i64) -> i32 {
    let conn = db::db();
    category_repo::delete(&conn, id)
        .map(|ok| ok as i32)
        .unwrap_or(0)
}

// =============================================================================
// M2 -- Reader / PDF pipeline commands (FEATURES §3)
// =============================================================================
//
// These commands bridge the Flutter reader UI to the pdfium-backed rendering
// pipeline. Bitmaps cross the FFI boundary as `Vec<u8>` (-> Dart `Uint8List`);
// errors are carried in sentinel structs per ARCHITECTURE §6 (no `Result`).

/// Result of opening a book for reading.
pub struct OpenBookResult {
    /// Total page count (0 if the document could not be opened).
    pub page_count: i64,
    /// Whether the document has a bookmark outline (FEATURES 3.4.2).
    pub has_outline: bool,
    /// Error message if opening failed; `None` on success.
    pub error: Option<String>,
}

/// A rendered page bitmap returned to Flutter for texture display (FEATURES 3.6).
pub struct PageRenderResult {
    pub width: u32,
    pub height: u32,
    /// RGBA pixels, row-major, length = width * height * 4.
    pub rgba: Vec<u8>,
    pub error: Option<String>,
}

/// The document outline / table of contents (FEATURES 3.4.2).
pub struct OutlineResult {
    pub entries: Vec<OutlineEntry>,
    pub error: Option<String>,
}

/// Open a book's PDF for reading (FEATURES 3.1). Must be called before
/// `render_page`, `get_outline`, etc. The document stays open until another
/// book is opened or `close_book` is called.
///
/// Async: pdfium document open is heavyweight and must not block the UI.
pub async fn open_book(stored_path: String) -> OpenBookResult {
    match pdf::open(&stored_path) {
        Ok(count) => {
            let has_outline = pdf::outline().map(|e| !e.is_empty()).unwrap_or(false);
            OpenBookResult {
                page_count: count,
                has_outline,
                error: None,
            }
        }
        Err(e) => OpenBookResult {
            page_count: 0,
            has_outline: false,
            error: Some(e.to_string()),
        },
    }
}

/// Close the currently-open document, freeing its memory.
pub async fn close_book() {
    pdf::close();
}

/// Render a page (0-indexed) to an RGBA bitmap (FEATURES 3.6.2).
/// `zoom` is the user zoom factor (1.0 = 100%); `dpi_scale` is the device
/// pixel ratio for high-DPI rendering.
///
/// Async: pdfium rendering is heavyweight and must not block the UI.
pub async fn render_page(book_id: i64, page: i64, zoom: f64, dpi_scale: f64) -> PageRenderResult {
    // `book_id` is accepted for API symmetry but the active document is used;
    // the caller must have opened this book via `open_book` first.
    let _ = book_id;
    match pdf::render_page(page, zoom as f32, dpi_scale as f32) {
        Ok(bmp) => PageRenderResult {
            width: bmp.width,
            height: bmp.height,
            rgba: bmp.rgba,
            error: None,
        },
        Err(e) => PageRenderResult {
            width: 0,
            height: 0,
            rgba: Vec::new(),
            error: Some(e.to_string()),
        },
    }
}

/// Render a small thumbnail for the sidebar (FEATURES 3.4.1).
///
/// Async: pdfium rendering is heavyweight and must not block the UI.
pub async fn render_thumbnail(book_id: i64, page: i64, max_size: u32) -> PageRenderResult {
    let _ = book_id;
    match pdf::thumbnail(page, max_size) {
        Ok(bmp) => PageRenderResult {
            width: bmp.width,
            height: bmp.height,
            rgba: bmp.rgba,
            error: None,
        },
        Err(e) => PageRenderResult {
            width: 0,
            height: 0,
            rgba: Vec::new(),
            error: Some(e.to_string()),
        },
    }
}

/// Fetch the document outline (FEATURES 3.4.2).
///
/// Async: pdfium bookmark traversal can be slow on large documents.
pub async fn get_outline(book_id: i64) -> OutlineResult {
    let _ = book_id;
    match pdf::outline() {
        Ok(entries) => OutlineResult {
            entries,
            error: None,
        },
        Err(e) => OutlineResult {
            entries: Vec::new(),
            error: Some(e.to_string()),
        },
    }
}

// -----------------------------------------------------------------------------
// Reading progress (FEATURES 3.3.4)
// -----------------------------------------------------------------------------

/// Load the saved reading position for a book. Returns `None` on first open.
pub fn get_progress(book_id: i64) -> Option<ReadingProgress> {
    let conn = db::db();
    progress_repo::get(&conn, book_id).ok().flatten()
}

/// Save the reading position (upsert). `view_mode` is the string form
/// ("single" / "double_scroll" / "double_page"). Returns 1 on success.
pub fn save_progress(book_id: i64, page: i64, zoom: f64, view_mode: String) -> i32 {
    let mode = ViewMode::from_db_str(&view_mode).unwrap_or(ViewMode::Single);
    let conn = db::db();
    progress_repo::save(&conn, book_id, page, zoom, mode)
        .map(|_| 1)
        .unwrap_or(0)
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

/// Encodes an RGBA bitmap as a PNG file using the `image` crate.
fn save_rgba_as_png(bmp: &PageBitmap, path: &Path) -> AppResult<()> {
    #[cfg(feature = "pdf")]
    {
        let img = image::RgbaImage::from_raw(bmp.width, bmp.height, bmp.rgba.clone())
            .ok_or_else(|| AppError::Pdf("failed to create image from rgba buffer".into()))?;
        image::DynamicImage::ImageRgba8(img)
            .save(path)
            .map_err(|e| AppError::Pdf(format!("save png: {e}")))?;
        Ok(())
    }
    #[cfg(not(feature = "pdf"))]
    {
        let _ = (bmp, path);
        Err(AppError::Pdf("image crate not available".into()))
    }
}

// =============================================================================
// M3 -- Text selection & annotations commands (FEATURES §4)
// =============================================================================
//
// Char-box extraction powers character-level drag selection (4.1.1); the
// annotations CRUD persists marks & notes (4.3/4.4); export renders Markdown /
// JSON for the sidebar (4.5). Errors follow the sentinel convention
// (ARCHITECTURE §6): `Option<String>` error fields, never `Result` across FFI.

use crate::db::repository::annotation as annotation_repo;
use crate::export;
use crate::models::annotation::{NormRect, TextAnnotation, TextAnnotationKind};

/// Per-character boxes of one page for selection hit-testing (FEATURES 4.1.1).
/// Coordinates are normalized [0,1] with a *top-left* origin (Flutter space).
pub struct CharBoxResult {
    pub boxes: Vec<CharBox>,
    pub error: Option<String>,
}

/// Result of creating an annotation: the new row id, or -1 on error.
pub struct AnnotationCreateResult {
    pub id: i64,
    pub error: Option<String>,
}

/// Text produced by an export command (Markdown / JSON, FEATURES 4.5.2/4.5.3).
pub struct ExportResult {
    pub content: String,
    pub error: Option<String>,
}

/// Extract per-character boxes for a page (0-indexed), normalized to [0,1]
/// with a top-left origin (Flutter coordinate space). Empty `boxes` means the
/// page has no text layer (scanned page -- OCR selection lands in M5).
///
/// Async: pdfium text traversal is heavyweight and must not block the UI.
pub async fn extract_text(book_id: i64, page: i64) -> CharBoxResult {
    let _ = book_id;
    match pdf::extract_text(page) {
        Ok(boxes) => CharBoxResult {
            boxes,
            error: None,
        },
        Err(e) => CharBoxResult {
            boxes: Vec::new(),
            error: Some(e.to_string()),
        },
    }
}

/// List all annotations of a book, ordered by page then creation (FEATURES
/// 4.5.1: the sidebar groups them by page).
pub fn list_annotations(book_id: i64) -> Vec<TextAnnotation> {
    let conn = db::db();
    annotation_repo::list(&conn, book_id).unwrap_or_default()
}

/// Create a text-layer annotation (highlight / underline / strikethrough /
/// note). `rects` holds one normalized rect per selected line (FEATURES
/// 4.3.1); `text` is the selected text; `content` the note body (notes only).
pub fn create_annotation(
    book_id: i64,
    page: i64,
    kind: TextAnnotationKind,
    text: Option<String>,
    content: Option<String>,
    rects: Vec<NormRect>,
    color: Option<String>,
) -> AnnotationCreateResult {
    let conn = db::db();
    match annotation_repo::create(&conn, book_id, page, kind, text, content, rects, color) {
        Ok(id) => AnnotationCreateResult { id, error: None },
        Err(e) => AnnotationCreateResult {
            id: -1,
            error: Some(e.to_string()),
        },
    }
}

/// Update a note's body text (FEATURES 4.4.2). Returns 1 on success.
pub fn update_annotation_content(annotation_id: i64, content: Option<String>) -> i32 {
    let conn = db::db();
    annotation_repo::update_content(&conn, annotation_id, content)
        .map(|_| 1)
        .unwrap_or(0)
}

/// Delete an annotation by id (FEATURES 4.4.2 / 4.5.1). Returns 1 on success.
pub fn delete_annotation(annotation_id: i64) -> i32 {
    let conn = db::db();
    annotation_repo::delete(&conn, annotation_id)
        .map(|_| 1)
        .unwrap_or(0)
}

/// Export all annotations of a book as Markdown (FEATURES 4.5.2): `# 阅读标注`
/// -> `## 第 N 页` -> one bullet per annotation, notes quoted underneath.
pub fn export_annotations_markdown(book_id: i64) -> ExportResult {
    let conn = db::db();
    match annotation_repo::list(&conn, book_id) {
        Ok(anns) => ExportResult {
            content: export::annotations_markdown(&anns),
            error: None,
        },
        Err(e) => ExportResult {
            content: String::new(),
            error: Some(e.to_string()),
        },
    }
}

/// Export all annotations of a book as pretty-printed JSON, including
/// coordinates and style (FEATURES 4.5.3).
pub fn export_annotations_json(book_id: i64) -> ExportResult {
    let conn = db::db();
    match annotation_repo::list(&conn, book_id) {
        Ok(anns) => ExportResult {
            content: export::annotations_json(book_id, &anns),
            error: None,
        },
        Err(e) => ExportResult {
            content: String::new(),
            error: Some(e.to_string()),
        },
    }
}

// =============================================================================
// M4 -- AI commands (FEATURES §6)
// =============================================================================
//
// BYOK OpenAI-compatible client: config persists in the `settings` table
// (6.1); chat actions stream SSE chunks over FRB `Stream<String>` (6.3).
// Cancellation is implicit: the Dart side cancels the subscription and the
// Rust request is dropped.

use crate::ai;
use crate::ai::AiClient as _;
use crate::db::repository::ai as ai_repo;
use crate::frb_generated::StreamSink;
use crate::models::ai::{AiActionType, AiConfig, AiMessage, AiRole, AiThread};


/// Load the BYOK AI configuration (FEATURES 6.1), or defaults on first run.
pub fn get_ai_config() -> AiConfig {
    let conn = db::db();
    conn.query_row(
        "SELECT value FROM settings WHERE key = 'ai_config'",
        [],
        |row| row.get::<_, String>(0),
    )
    .ok()
    .and_then(|json| serde_json::from_str(&json).ok())
    .unwrap_or_default()
}

/// Persist the AI configuration (FEATURES 6.1.1-6.1.5). Returns 1 on success.
pub fn set_ai_config(config: AiConfig) -> i32 {
    let conn = db::db();
    let json = serde_json::to_string(&config).unwrap_or_default();
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES \
             ('ai_config', ?1, datetime('now')) \
         ON CONFLICT(key) DO UPDATE SET \
            value = excluded.value, updated_at = excluded.updated_at",
        rusqlite::params![json],
    )
    .map(|_| 1)
    .unwrap_or(0)
}

/// Result of creating a persisted thread (FEATURES 6.5.4). `id` is -1 and
/// `error` set on failure (sentinel convention: no `Result` across FRB).
pub struct AiThreadCreateResult {
    pub id: i64,
    pub error: Option<String>,
}

/// List all persisted conversation threads, most recently updated first
/// (FEATURES 6.5.3 / 6.5.4). Empty vec on failure.
pub fn list_ai_threads() -> Vec<AiThread> {
    let conn = db::db();
    ai_repo::list_threads(&conn).unwrap_or_default()
}

/// List one thread's messages in conversation order (6.5.4).
pub fn list_ai_messages(thread_id: i64) -> Vec<AiMessage> {
    let conn = db::db();
    ai_repo::list_messages(&conn, thread_id).unwrap_or_default()
}

/// Persist a new conversation window; returns its id (-1 on failure).
/// `book_id` binds the window to a book (null = the no-book window); one
/// window per book is enforced by a unique partial index (6.5.4).
pub fn create_ai_thread(
    title: String,
    action_type: AiActionType,
    book_id: Option<i64>,
) -> AiThreadCreateResult {
    let conn = db::db();
    match ai_repo::create_thread(&conn, &title, action_type, book_id) {
        Ok(id) => AiThreadCreateResult { id, error: None },
        Err(e) => AiThreadCreateResult {
            id: -1,
            error: Some(e.to_string()),
        },
    }
}

/// Append a message to a window and bump its `updated_at`; `action_type`
/// (when set) becomes the window's latest action for the history icon.
/// Returns 1 on success (0 if the window does not exist).
pub fn append_ai_message(
    thread_id: i64,
    role: AiRole,
    content: String,
    action_type: Option<AiActionType>,
) -> i32 {
    let conn = db::db();
    match ai_repo::append_message(&conn, thread_id, role, &content, action_type) {
        Ok(()) => 1,
        Err(_) => 0,
    }
}

/// Delete one conversation window (its messages cascade). Returns 1 if the
/// window existed, 0 otherwise (6.5.3 per-window deletion).
pub fn delete_ai_thread(thread_id: i64) -> i32 {
    let conn = db::db();
    match ai_repo::delete_thread(&conn, thread_id) {
        Ok(true) => 1,
        _ => 0,
    }
}

/// The AI client for this build (real impl with the `ai` feature).
#[cfg(feature = "ai")]
fn ai_client() -> impl ai::AiClient {
    ai::OpenAiClient
}

#[cfg(not(feature = "ai"))]
fn ai_client() -> ai::StubAiClient {
    ai::StubAiClient::new()
}

/// System prompt for a text action (FEATURES 6.2). For Search with real web
/// search enabled this runs the Bocha query first (async), so the prompt
/// construction is async too.
async fn system_prompt_for(action: AiActionType, config: &AiConfig, text: &str) -> String {
    match action {
        AiActionType::Translate => ai::prompts::translate_system(&config.translate_target_lang),
        AiActionType::Explain => ai::prompts::explain_system(),
        AiActionType::Search => search_system_prompt(config, text).await,
        AiActionType::Chat => ai::prompts::chat_system(),
        // Vision uses its own message builder (vision_prompt + the
        // screenshot data URL, see stream_vision_png); the enum value is
        // kept for thread compatibility.
        AiActionType::Vision => ai::prompts::chat_system(),
    }
}

/// Search system prompt with real results (FEATURES 6.2.3): enabled + key ->
/// Bocha query, results embedded; enabled without key -> knowledge fallback
/// that says so; search failure -> knowledge fallback that names the error.
#[cfg(feature = "ai")]
async fn search_system_prompt(config: &AiConfig, query: &str) -> String {
    if !config.web_search_enabled {
        return ai::prompts::search_system(false);
    }
    let Some(key) = config
        .search_api_key
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return ai::prompts::search_no_key_system();
    };
    // Empty search_base_url -> Bocha default endpoint (any Bocha-compatible
    // provider can be configured here, 6.1.4).
    let base_url = config.search_base_url.as_deref().unwrap_or("");
    match ai::web_search(base_url, key, query).await {
        Ok(results) => ai::prompts::search_system_with_results(&results),
        Err(e) => ai::prompts::search_failed_system(&e.to_string()),
    }
}

#[cfg(not(feature = "ai"))]
async fn search_system_prompt(config: &AiConfig, _query: &str) -> String {
    ai::prompts::search_system(config.web_search_enabled)
}

/// Streaming text action (translate / explain / search / chat, FEATURES
/// 6.2). `history` carries the thread's prior turns (6.5.2); the action's
/// system prompt is prepended here. Emits SSE chunks; errors (including
/// "not configured", 10.4) arrive on the stream's error channel.
pub async fn stream_chat(
    action: AiActionType,
    text: String,
    history: Vec<AiMessage>,
    sink: StreamSink<String>,
) {
    let config = get_ai_config();
    if config.api_key.trim().is_empty() {
        let _ = sink.add_error(
            "未配置 API Key：请在「设置 → AI 配置」中填写（FEATURES 10.4 离线提示）".to_string(),
        );
        return;
    }

    // Built-in web search (Responses API, 6.2.3): a different streaming
    // protocol with server-side search, handled directly.
    if action == AiActionType::Search && config.web_search_enabled && config.search_use_builtin {
        return builtin_search_stream(&config, &text, &history, sink).await;
    }

    let client = ai_client();
    let system = AiMessage {
        id: -1,
        thread_id: -1,
        role: AiRole::System,
        content: system_prompt_for(action, &config, &text).await,
        created_at: String::new(),
    };
    let mut messages = history;
    messages.insert(0, system);
    match client.stream_chat(&config, &messages, &text).await {
        Ok(stream) => drain_stream(stream, sink).await,
        Err(e) => {
            let _ = sink.add_error(e.to_string());
        }
    }
}

/// Streaming vision analysis of a captured region screenshot (识图, FEATURES
/// 6.6.2 / 7.2): the PNG is sent to the vision model as a data URL and the
/// answer streams back like [stream_chat]. Cancellation is implicit (6.3.2).
/// The screenshot itself is pixel-exact (captured straight from the window's
/// composited layer), so what the model sees is exactly what was selected.
pub async fn stream_vision_png(png: Vec<u8>, sink: StreamSink<String>) {
    let config = get_ai_config();
    if config.api_key.trim().is_empty() {
        let _ = sink.add_error(
            "未配置 API Key：请在「设置 → AI 配置」中填写（FEATURES 10.4 离线提示）".to_string(),
        );
        return;
    }
    if png.is_empty() {
        let _ = sink.add_error("截图数据为空".to_string());
        return;
    }
    let client = ai_client();
    let prompt = ai::prompts::vision_prompt();
    match client.stream_vision(&config, &png, &prompt).await {
        Ok(stream) => drain_stream(stream, sink).await,
        Err(e) => {
            let _ = sink.add_error(e.to_string());
        }
    }
}

/// Forward a chunk stream to the FRB sink; stops when the Dart side cancels
/// the subscription (6.3.2).
async fn drain_stream(mut stream: ai::ChunkStream, sink: StreamSink<String>) {
    use tokio_stream::StreamExt as _;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(t) => {
                // Dart cancelled the subscription -> send fails.
                if sink.add(t).is_err() {
                    break;
                }
            }
            Err(e) => {
                let _ = sink.add_error(e.to_string());
                break;
            }
        }
    }
}

/// Search with the provider's built-in web search (Responses API, 6.2.3):
/// the search system prompt goes into the API's `instructions` slot and the
/// provider runs the search server-side. On failure the call falls back to a
/// knowledge answer that names the search error (no silent degradation).
#[cfg(feature = "ai")]
async fn builtin_search_stream(
    config: &AiConfig,
    query: &str,
    history: &[AiMessage],
    sink: StreamSink<String>,
) {
    let mut messages = history.to_vec();
    let system = AiMessage {
        id: -1,
        thread_id: -1,
        role: AiRole::System,
        content: ai::prompts::search_system(true),
        created_at: String::new(),
    };
    messages.insert(0, system);
    match ai::web_search_builtin(
        &config.base_url,
        &config.api_key,
        &config.text_model,
        &messages,
        query,
    )
    .await
    {
        Ok(stream) => drain_stream(stream, sink).await,
        Err(e) => {
            // Fallback: answer from knowledge, noting the search failure.
            messages[0].content = ai::prompts::search_failed_system(&e.to_string());
            let client = ai_client();
            match client.stream_chat(config, &messages, query).await {
                Ok(stream) => drain_stream(stream, sink).await,
                Err(e2) => {
                    let _ = sink.add_error(e2.to_string());
                }
            }
        }
    }
}

#[cfg(not(feature = "ai"))]
async fn builtin_search_stream(
    _config: &AiConfig,
    _query: &str,
    _history: &[AiMessage],
    sink: StreamSink<String>,
) {
    let _ = sink.add_error("AI support not compiled in (feature 'ai' disabled)".to_string());
}
