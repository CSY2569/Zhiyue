//! Bilingual reading subsystem (M7, `docs/BILINGUAL_READING_PLAN.md`).
//!
//! Paragraph-level translation alongside the original page: extraction
//! ([extract]) runs on INDEPENDENT pdfium documents so whole-book work never
//! blocks the reader's page rendering (plan §3.0); translation providers
//! ([providers], stage 2) align strictly per paragraph and protect formulas
//! with placeholders; the on-demand translated-PDF writer ([pdf_writer],
//! stage 5) walks cached pages 1..N.
//!
//! Orchestration is Dart-side (plan §9): a Riverpod queue calls the atomic
//! per-page API. This module keeps a small registry of books with in-flight
//! translations so cache eviction never touches active work (plan §7).

#[cfg(feature = "pdf")]
pub mod extract;
#[cfg(feature = "ai")]
pub mod providers;
#[cfg(all(feature = "pdf", feature = "ai"))]
pub mod pipeline;
#[cfg(all(feature = "pdf", feature = "ai"))]
pub mod pdf_writer;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use sha2::{Digest, Sha256};

use crate::db;
use crate::error::{AppError, AppResult};
use crate::models::translate::{TranslationConfig, TranslationOverview};

/// Books with translation work in flight (a whole-book task or a single
/// page). [crate::translate] eviction checks must skip these (plan §7:
/// 正在翻译的书不可逐出).
static TRANSLATING: OnceLock<Mutex<HashSet<i64>>> = OnceLock::new();

fn translating() -> &'static Mutex<HashSet<i64>> {
    TRANSLATING.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Registers a book as being translated right now.
pub fn mark_translating(book_id: i64) {
    translating().lock().unwrap().insert(book_id);
}

/// Removes the registration (page done / task cancelled).
pub fn unmark_translating(book_id: i64) {
    translating().lock().unwrap().remove(&book_id);
}

/// Whether a book has translation work in flight.
pub fn is_translating(book_id: i64) -> bool {
    translating().lock().unwrap().contains(&book_id)
}

/// All books currently translating (eviction skip-list).
pub fn translating_books() -> Vec<i64> {
    translating().lock().unwrap().iter().copied().collect()
}

/// `{data_dir}/translated/{book_id}` -- translated PDFs + formula images
/// (plan §6/§7). Sibling of `covers/` / `ai_images/`.
pub fn translated_dir(book_id: i64) -> PathBuf {
    db::app_data_dir()
        .unwrap_or_default()
        .join("translated")
        .join(book_id.to_string())
}

/// SHA-256 over the page's paragraph texts: the cache freshness guard
/// (plan §2 -- a re-extracted page whose text changed invalidates the
/// cached translation).
pub fn source_hash(texts: &[&str]) -> String {    let mut hasher = Sha256::new();
    for t in texts {
        hasher.update(t.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    let mut hex = String::with_capacity(digest.len() * 2);
    for b in digest {
        hex.push_str(&format!("{b:02x}"));
    }
    hex
}

// =============================================================================
// Extractor version stamp (cache invalidation across algorithm changes)
// =============================================================================

/// Version of the paragraph-extraction algorithm. Bump whenever extraction,
/// noise removal or formula detection changes in a way that invalidates
/// previously cached translations. Every cached `source_hash` is stamped
/// `vN:<sha>`; rows with an older stamp are treated as absent so a fix takes
/// effect on already-translated books (regression: a formula-detection bug
/// made whole books untranslatable, then stayed masked by their cache).
/// v3: cached rows also carry per-paragraph line rects (the overlay writer's
/// positioning input); older rows are re-translated to gain them.
pub const EXTRACTOR_VERSION: u32 = 3;

/// Stamps a source hash with the current extractor version.
pub fn stamp_source_hash(hash: &str) -> String {
    format!("v{EXTRACTOR_VERSION}:{hash}")
}

/// Whether a cached row's `source_hash` was produced by the CURRENT extractor
/// (an older / unstamped row predates an extraction fix and is stale).
pub fn is_current_source_hash(hash: &str) -> bool {
    hash.starts_with(&format!("v{EXTRACTOR_VERSION}:"))
}

// =============================================================================
// Config + overview (pure DB, no cargo features needed)
// =============================================================================

/// Reads the translation config from the settings KV (`translation_config`,
/// plan §8); a missing / corrupt row falls back to defaults.
pub fn load_translation_config() -> TranslationConfig {
    let conn = db::db();
    load_translation_config_with(&conn)
}

/// Same as [load_translation_config] but reuses an already-held connection.
///
/// The process-wide DB handle is a non-reentrant `Mutex`; a function that
/// holds the guard must never call `db::db()` again (it self-deadlocks --
/// regression: `translation_overview` did exactly that and hung every
/// translation on book open). Callers holding a guard use this variant.
pub fn load_translation_config_with(conn: &rusqlite::Connection) -> TranslationConfig {
    conn.query_row(
        "SELECT value FROM settings WHERE key = 'translation_config'",
        [],
        |row| row.get::<_, String>(0),
    )
    .ok()
    .and_then(|json| serde_json::from_str(&json).ok())
    .unwrap_or_default()
}

/// Upserts the translation config.
pub fn save_translation_config(config: &TranslationConfig) -> AppResult<()> {
    let json = serde_json::to_string(config)?;
    let conn = db::db();
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES ('translation_config', ?1, datetime('now')) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')",
        rusqlite::params![json],
    )?;
    Ok(())
}

/// Reads the AI config (same KV row the AI settings page writes; the
/// translation target language lives there, plan §8 v4.2 user decision).
pub fn load_ai_config() -> crate::models::ai::AiConfig {
    let conn = db::db();
    load_ai_config_with(&conn)
}

/// Same as [load_ai_config] but reuses an already-held connection (see
/// [load_translation_config_with] for why re-locking deadlocks).
pub fn load_ai_config_with(conn: &rusqlite::Connection) -> crate::models::ai::AiConfig {
    conn.query_row(
        "SELECT value FROM settings WHERE key = 'ai_config'",
        [],
        |row| row.get::<_, String>(0),
    )
    .ok()
    .and_then(|json| serde_json::from_str(&json).ok())
    .unwrap_or_default()
}

/// The cache-key pair for lookups: the CONFIGURED target language (the
/// effective one for 中英互译 varies per page and is recorded inside the
/// row, not in the key) and the provider id.
pub fn cache_key() -> (String, String) {
    let conn = db::db();
    cache_key_with(&conn)
}

/// Same as [cache_key] but reuses an already-held connection (deadlock-safe).
pub fn cache_key_with(conn: &rusqlite::Connection) -> (String, String) {
    let ai = load_ai_config_with(conn);
    let tc = load_translation_config_with(conn);
    (
        ai.translate_target_lang.trim().to_string(),
        tc.provider.as_str().to_string(),
    )
}

/// Whole-book progress for the current target language + provider
/// (plan §9: the resume decision -- translated < total means unfinished).
pub fn translation_overview(book_id: i64) -> AppResult<TranslationOverview> {
    let conn = db::db();
    let (total_pages, title): (i64, String) = conn
        .query_row(
            "SELECT page_count, title FROM books WHERE id = ?1",
            rusqlite::params![book_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .map_err(|_| AppError::NotFound(format!("书籍不存在 (id={book_id})")))?;
    let _ = title;
    // Reuse the held guard: `cache_key()` would call `db::db()` again and
    // self-deadlock this non-reentrant mutex (the "no API call" root cause).
    let (lang, provider) = cache_key_with(&conn);
    let translated_pages = crate::db::repository::translate::translated_pages(
        &conn, book_id, &lang, &provider,
    )?
    .len() as i64;
    Ok(TranslationOverview {
        book_id,
        total_pages,
        translated_pages,
        target_lang: lang,
    })
}

/// Deletes every cached translation of a book (rows + `translated/`
/// artifacts, plan §7) and cancels any in-flight registration.
pub fn clear_translations(book_id: i64) -> AppResult<()> {
    {
        let conn = db::db();
        crate::db::repository::translate::clear_book_translations(&conn, book_id)?;
    }
    unmark_translating(book_id);
    let dir = translated_dir(book_id);
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    Ok(())
}

// =============================================================================
// Feature-gate fallbacks (the api layer's M7 functions must exist in every
// build; without pdf + ai they return explicit errors, mirroring pdf::fallback)
// =============================================================================

#[cfg(not(all(feature = "pdf", feature = "ai")))]
pub mod pipeline_fallback {
    use super::*;
    use crate::models::translate::TranslationProgressEvent;

    pub async fn run_translate_page(
        _book_id: i64,
        page: i64,
        _force: bool,
        mut on_event: impl FnMut(TranslationProgressEvent),
    ) -> AppResult<crate::models::translate::PageTranslation> {
        on_event(TranslationProgressEvent {
            page,
            done_paragraphs: 0,
            total_paragraphs: 0,
            coverage: 0.0,
            finished: true,
            error: Some("对照阅读需要 pdf + ai 构建特性".into()),
        });
        Err(AppError::Internal(
            "对照阅读需要 pdf + ai 构建特性".into(),
        ))
    }

    pub fn extract_paragraphs(_book_id: i64, _page: i64) -> AppResult<Vec<crate::models::translate::Paragraph>> {
        Err(AppError::Internal("段落抽取需要 pdf 构建特性".into()))
    }
}

#[cfg(not(all(feature = "pdf", feature = "ai")))]
pub use pipeline_fallback as pipeline;

/// Builds the translated PDF (plan §6). With `pdf` + `ai` this is the real
/// writer; otherwise an explicit error. Kept as a top-level dispatch so the
/// api layer has one stable name in every build.
#[cfg(all(feature = "pdf", feature = "ai"))]
pub fn build_translated_pdf(
    book_id: i64,
    target_lang: &str,
    on_event: impl FnMut(crate::models::translate::TranslationProgressEvent),
) -> AppResult<String> {
    let path = pdf_writer::build_translated_pdf(book_id, target_lang, on_event)?;
    // Plan §7 check timing: after an export build, enforce the budget so the
    // freshly written artifacts cannot push storage indefinitely.
    if let Err(e) = enforce_cache_limit() {
        tracing::warn!(?e, "translation cache eviction after export failed");
    }
    Ok(path)
}

#[cfg(not(all(feature = "pdf", feature = "ai")))]
pub fn build_translated_pdf(
    _book_id: i64,
    _target_lang: &str,
    mut on_event: impl FnMut(crate::models::translate::TranslationProgressEvent),
) -> AppResult<String> {
    on_event(crate::models::translate::TranslationProgressEvent {
        page: 0,
        done_paragraphs: 0,
        total_paragraphs: 0,
        coverage: 0.0,
        finished: true,
        error: Some("译文 PDF 生成需要 pdf + ai 构建特性".into()),
    });
    Err(AppError::Internal(
        "译文 PDF 生成需要 pdf + ai 构建特性".into(),
    ))
}

/// Renders ONE translated page to RGBA for the bilingual pane's page-level
/// view (plan §5): the translation is shown as a real PDF page beside the
/// original instead of a text list.
#[cfg(all(feature = "pdf", feature = "ai"))]
pub fn render_translated_page(
    book_id: i64,
    page: i64,
    target_lang: &str,
    dpi_scale: f32,
) -> AppResult<crate::pdf::types::PageBitmap> {
    pdf_writer::render_translated_page(book_id, page, target_lang, dpi_scale)
}

#[cfg(not(all(feature = "pdf", feature = "ai")))]
pub fn render_translated_page(
    _book_id: i64,
    _page: i64,
    _target_lang: &str,
    _dpi_scale: f32,
) -> AppResult<crate::pdf::types::PageBitmap> {
    Err(AppError::Internal(
        "译文页渲染需要 pdf + ai 构建特性".into(),
    ))
}

/// Whether the page currently has a translatable cached translation (the
/// pane uses this to decide between showing the rendered page and a prompt).
pub fn page_has_translation(book_id: i64, page: i64) -> bool {
    let conn = db::db();
    let (lang, provider) = cache_key_with(&conn);
    crate::db::repository::translate::get_page_translation(
        &conn, book_id, page, &lang, &provider, false,
    )
    .ok()
    .flatten()
    .map(|t| is_current_source_hash(&t.source_hash))
    .unwrap_or(false)
}

/// Deletes a book's translated artifacts (PDF + formula images) without
/// touching the cache rows (used by delete_book, which cascades the rows).
pub fn clear_translation_artifacts(book_id: i64) -> AppResult<()> {
    let dir = translated_dir(book_id);
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    Ok(())
}

/// KV key holding the pinned book ids (JSON array); pinned books are never
/// evicted by the LRU sweep (plan §7).
pub const PINNED_BOOKS_KEY: &str = "translation_pinned_books";

/// Pinned book ids from the settings KV.
pub fn pinned_books() -> Vec<i64> {
    let conn = db::db();
    let raw: Option<String> = conn
        .query_row(
            "SELECT value FROM settings WHERE key = ?1",
            rusqlite::params![PINNED_BOOKS_KEY],
            |row| row.get(0),
        )
        .ok();
    raw.and_then(|s| serde_json::from_str::<Vec<i64>>(&s).ok())
        .unwrap_or_default()
}

/// Enforces the translation cache budget (plan §7): when `translated/`
/// exceeds `cache_limit_mb`, the least-recently-used books' ARTIFACTS are
/// deleted (PDF + formula images); the tiny paragraph cache rows stay so
/// translation can be rebuilt instantly. Pinned books, the currently-open
/// book and books with in-flight work are skipped. Runs quietly at startup
/// and after an export build.
pub fn enforce_cache_limit() -> AppResult<u64> {
    let config = load_translation_config();
    let limit_bytes = (config.cache_limit_mb.max(0) as u64) * 1024 * 1024;
    if limit_bytes == 0 {
        return Ok(0);
    }
    let mut used = db::repository::translate::translated_dir_size();
    if used <= limit_bytes {
        return Ok(used);
    }

    let pinned: std::collections::HashSet<i64> = pinned_books().into_iter().collect();
    let translating: std::collections::HashSet<i64> =
        translating_books().into_iter().collect();
    let books = {
        let conn = db::db();
        db::repository::translate::books_by_recency(&conn)?
    };
    for (book_id, _) in books {
        if used <= limit_bytes {
            break;
        }
        if pinned.contains(&book_id) || translating.contains(&book_id) {
            continue;
        }
        let dir = translated_dir(book_id);
        let before = dir_size(&dir);
        if dir.exists() {
            std::fs::remove_dir_all(&dir)?;
        }
        used = used.saturating_sub(before);
    }
    Ok(used)
}

fn dir_size(dir: &std::path::Path) -> u64 {
    let mut total = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_dir() {
                total += dir_size(&p);
            } else if let Ok(md) = entry.metadata() {
                total += md.len();
            }
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_hash_is_stable_and_order_sensitive() {
        let a = source_hash(&["hello", "world"]);
        let b = source_hash(&["hello", "world"]);
        let c = source_hash(&["helloworld"]);
        let d = source_hash(&["world", "hello"]);
        assert_eq!(a, b);
        assert_ne!(a, c, "separator must contribute");
        assert_ne!(a, d, "order must matter");
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn translating_registry_roundtrip() {
        // Use a book id no other test touches concurrently.
        let id = 987_654_321;
        assert!(!is_translating(id));
        mark_translating(id);
        assert!(is_translating(id));
        assert!(translating_books().contains(&id));
        unmark_translating(id);
        assert!(!is_translating(id));
    }
}
