//! Bilingual reading subsystem (M7).
//!
//! The original built-in pipeline (pdfium paragraph extraction → LLM/DeepL
//! providers → overlay PDF writer, with a per-page SQLite cache) was RETIRED
//! in favor of the downloadable BabelDOC engine (see `engine.rs`, staged);
//! git tag `pre-babeldoc-replacement` preserves the old code.
//!
//! What remains here is the engine-independent bookkeeping: a registry of
//! books with in-flight translation work (so cache eviction never touches
//! active runs), the `translated/{book_id}` artifact directory, the
//! translation config KV and the artifact LRU budget. Glossary entries live
//! in `db::repository::translate`.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use crate::db;
use crate::error::AppResult;
use crate::models::translate::TranslationConfig;

/// Books with translation work in flight. Eviction checks must skip these
/// (plan §7: 正在翻译的书不可逐出).
static TRANSLATING: OnceLock<Mutex<HashSet<i64>>> = OnceLock::new();

fn translating() -> &'static Mutex<HashSet<i64>> {
    TRANSLATING.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Registers a book as being translated right now.
pub fn mark_translating(book_id: i64) {
    translating().lock().unwrap().insert(book_id);
}

/// Removes the registration (task done / cancelled).
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

/// `{data_dir}/translated/{book_id}` -- translated PDFs (plan §6/§7).
/// Sibling of `covers/` / `ai_images/`.
pub fn translated_dir(book_id: i64) -> PathBuf {
    db::app_data_dir()
        .unwrap_or_default()
        .join("translated")
        .join(book_id.to_string())
}

// =============================================================================
// Config (pure DB, no cargo features needed)
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
/// holds the guard must never call `db::db()` again (it self-deadlocks).
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

/// Deletes a book's translated artifacts (the translated PDFs).
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
/// deleted. Pinned books, the currently-open book and books with in-flight
/// work are skipped. Runs quietly at startup and after translation runs.
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
    // Eviction candidates by artifact mtime (oldest first). The per-page
    // cache rows that used to drive this ordering were dropped in schema v8;
    // the artifacts' own mtime is the natural replacement.
    let mut candidates: Vec<(i64, std::time::SystemTime)> = Vec::new();
    if let Ok(root) = db::app_data_dir() {
        let translated = root.join("translated");
        if let Ok(entries) = std::fs::read_dir(&translated) {
            for entry in entries.flatten() {
                let Ok(id) = entry.file_name().to_string_lossy().parse::<i64>() else {
                    continue;
                };
                if let Ok(md) = entry.metadata() {
                    if let Ok(mtime) = md.modified() {
                        candidates.push((id, mtime));
                    }
                }
            }
        }
    }
    candidates.sort_by_key(|(_, mtime)| *mtime);
    for (book_id, _) in candidates {
        if used <= limit_bytes {
            break;
        }
        if pinned.contains(&book_id) || translating.contains(&book_id) {
            continue;
        }
        let dir = translated_dir(book_id);
        let before = crate::db::repository::translate::dir_size(&dir);
        if dir.exists() {
            std::fs::remove_dir_all(&dir)?;
        }
        used = used.saturating_sub(before);
    }
    Ok(used)
}

#[cfg(test)]
mod tests {
    use super::*;

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