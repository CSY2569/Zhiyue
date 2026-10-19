//! Bilingual reading subsystem (M7).
//!
//! The original built-in pipeline (pdfium paragraph extraction → LLM/DeepL
//! providers → overlay PDF writer, with a per-page SQLite cache) was RETIRED
//! in favor of an external engine sidecar (see `engine.rs`, `job.rs`, staged);
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

/// Whether ANY book has translation work in flight (engine uninstall guard).
pub fn is_translating_any() -> bool {
    !translating().lock().unwrap().is_empty()
}

#[cfg(feature = "ai")]
pub mod engine;
#[cfg(feature = "ai")]
pub mod flat_ocr;
#[cfg(feature = "ai")]
pub mod job;

/// `{data_dir}/retain_output/{book_id}` -- the engine's persistent scratch
/// (translation-unit cache, domain cache, typography memory). Kept ACROSS
/// runs so a retry / re-translate reuses already-paid LLM work; bounded by
/// [enforce_output_cache_cap] and dropped with the book.
pub fn output_cache_dir(book_id: i64) -> PathBuf {
    db::app_data_dir()
        .unwrap_or_default()
        .join("retain_output")
        .join(book_id.to_string())
}

/// Removes one book's engine output cache (delete-book cascade).
pub fn clear_output_cache(book_id: i64) -> AppResult<()> {
    let dir = output_cache_dir(book_id);
    if dir.exists() {
        std::fs::remove_dir_all(dir)?;
    }
    Ok(())
}

/// Total bytes under `{data_dir}/retain_output`.
fn output_cache_total() -> u64 {
    let Some(root) = db::app_data_dir().ok().map(|d| d.join("retain_output")) else {
        return 0;
    };
    let mut total = 0u64;
    if let Ok(entries) = std::fs::read_dir(&root) {
        for entry in entries.flatten() {
            total += crate::db::repository::translate::dir_size(&entry.path());
        }
    }
    total
}

/// Cap the engine output caches (default 2GB): evict whole books oldest-first,
/// skipping pinned / in-flight ones (same policy as the artifact LRU).
pub fn enforce_output_cache_cap() -> AppResult<()> {
    const CAP_BYTES: u64 = 2 * 1024 * 1024 * 1024;
    let root = db::app_data_dir()?.join("retain_output");
    let used = output_cache_total();
    evict_lru(&root, used, CAP_BYTES, &eviction_skip_set(), |_| {})?;
    Ok(())
}

/// Book directories under [root] whose name is a book id, oldest first.
fn book_dirs_by_mtime(root: &std::path::Path) -> Vec<(i64, std::time::SystemTime)> {
    let mut candidates: Vec<(i64, std::time::SystemTime)> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(root) {
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
    candidates.sort_by_key(|(_, mtime)| *mtime);
    candidates
}

/// Delete whole-book directories under [root] oldest-first until [used]
/// drops to [cap]. Book ids in [skip] are never touched. [on_evict] runs
/// after each removal (the artifact LRU uses it to drop the book's engine
/// scratch too).
fn evict_lru(
    root: &std::path::Path,
    mut used: u64,
    cap: u64,
    skip: &std::collections::HashSet<i64>,
    mut on_evict: impl FnMut(i64),
) -> AppResult<u64> {
    if used <= cap {
        return Ok(used);
    }
    for (book_id, _) in book_dirs_by_mtime(root) {
        if used <= cap {
            break;
        }
        if skip.contains(&book_id) {
            continue;
        }
        let dir = root.join(book_id.to_string());
        let before = crate::db::repository::translate::dir_size(&dir);
        if dir.exists() {
            std::fs::remove_dir_all(&dir)?;
        }
        on_evict(book_id);
        used = used.saturating_sub(before);
    }
    Ok(used)
}

/// Books excluded from eviction: pinned + currently translating.
fn eviction_skip_set() -> std::collections::HashSet<i64> {
    pinned_books()
        .into_iter()
        .chain(translating_books())
        .collect()
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
    crate::db::repository::settings::get_json(conn, "translation_config").unwrap_or_default()
}

/// Upserts the translation config.
pub fn save_translation_config(config: &TranslationConfig) -> AppResult<()> {
    let conn = db::db();
    crate::db::repository::settings::set_json(&conn, "translation_config", config)
}

/// The AI configuration the engine job reuses (BYOK OpenAI-compatible
/// endpoint; the translation target language also lives there).
#[cfg(feature = "ai")]
pub fn load_ai_config_for_job() -> AppResult<crate::models::ai::AiConfig> {
    let conn = db::db();
    Ok(crate::db::repository::settings::get_json(&conn, "ai_config").unwrap_or_default())
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
    crate::db::repository::settings::get_json(&conn, PINNED_BOOKS_KEY).unwrap_or_default()
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
    let used = db::repository::translate::translated_dir_size();
    // Eviction candidates by artifact mtime (oldest first). The per-page
    // cache rows that used to drive this ordering were dropped in schema v8;
    // the artifacts' own mtime is the natural replacement.
    let root = db::app_data_dir()?.join("translated");
    evict_lru(&root, used, limit_bytes, &eviction_skip_set(), |book_id| {
        // The engine's per-book caches are part of the same budget.
        let cache = output_cache_dir(book_id);
        if cache.exists() {
            let _ = std::fs::remove_dir_all(&cache);
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The engine's scratch lives per book under retain_output/ (persistent
    /// across runs so retries reuse paid LLM work).
    #[test]
    fn output_cache_dir_is_per_book_and_persistent() {
        let a = output_cache_dir(7);
        let b = output_cache_dir(8);
        assert!(a.to_string_lossy().contains("retain_output/7"), "{a:?}");
        assert_ne!(a, b);
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

    /// LRU sweep: oldest first, skip-list honored, stops at the budget, and
    /// the eviction callback sees each removed book exactly once.
    #[test]
    fn evict_lru_orders_skips_and_budgets() {
        let root = std::env::temp_dir().join(format!(
            "rbwa-lru-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        // Three books, each holding 10 bytes; distinct mtimes via sleeps.
        for id in [1_i64, 2, 3] {
            let dir = root.join(id.to_string());
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(dir.join("f"), vec![0u8; 10]).unwrap();
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let skip: std::collections::HashSet<i64> = [1].into_iter().collect();
        let mut evicted = Vec::new();
        let used = evict_lru(&root, 30, 10, &skip, |id| evicted.push(id)).unwrap();

        // Book 1 is pinned; 2 is older than 3, so eviction is [2, 3].
        assert_eq!(evicted, vec![2, 3], "oldest-first, skip-list honored");
        assert_eq!(used, 10);
        assert!(root.join("1").exists());
        assert!(!root.join("2").exists());
        assert!(!root.join("3").exists());
        // Under budget: no work.
        assert_eq!(evict_lru(&root, 10, 10, &skip, |_| {}).unwrap(), 10);
        std::fs::remove_dir_all(&root).ok();
    }
}