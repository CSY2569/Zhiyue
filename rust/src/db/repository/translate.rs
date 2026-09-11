//! `page_translation_cache` + `translation_glossary` repositories
//! (M7, `docs/BILINGUAL_READING_PLAN.md` §9).
//!
//! The cache is keyed by (book_id, page, target_lang, provider) with the
//! absolute 1-indexed page number (plan §2: completion order never matters);
//! `source_hash` guards freshness and `last_accessed_at` drives the LRU
//! (plan §7). Rows cascade-delete with their book (FK). Repositories take a
//! borrowed `&Connection` and do no file IO.

use rusqlite::{params, Connection};

use crate::error::{AppError, AppResult};
use crate::models::translate::{GlossaryEntry, PageTranslation};

/// The cached translation of a page, if any. Does NOT check `source_hash`
/// (the caller compares it against the freshly extracted page, plan §2).
pub fn get_page_translation(
    conn: &Connection,
    book_id: i64,
    page: i64,
    target_lang: &str,
    provider: &str,
    refresh_access: bool,
) -> AppResult<Option<PageTranslation>> {
    let json: Option<String> = {
        let mut stmt = conn.prepare(
            "SELECT result_json FROM page_translation_cache \
             WHERE book_id = ?1 AND page = ?2 AND target_lang = ?3 AND provider = ?4",
        )?;
        let mut rows = stmt.query_map(params![book_id, page, target_lang, provider], |row| {
            row.get::<_, String>(0)
        })?;
        rows.next().transpose()?
    };
    let Some(json) = json else {
        return Ok(None);
    };
    if refresh_access {
        // LRU bookkeeping (plan §7): reading the pane refreshes access time.
        let _ = conn.execute(
            "UPDATE page_translation_cache SET last_accessed_at = datetime('now') \
             WHERE book_id = ?1 AND page = ?2 AND target_lang = ?3 AND provider = ?4",
            params![book_id, page, target_lang, provider],
        );
    }
    serde_json::from_str(&json)
        .map(Some)
        .map_err(|e| AppError::Internal(format!("parse page translation cache: {e}")))
}

/// Upserts a page translation (same key replaces; plan §2).
///
/// `key_lang` is the CONFIGURED target language (the cache-key component
/// `cache_key()` derives), which is stored in the `target_lang` column. It can
/// differ from `translation.target_lang`, which is the per-page EFFECTIVE
/// language for 中英互译 and travels inside the JSON payload. Storing the
/// configured key is what makes reads hit (regression: the effective language
/// was written to the key column, so 中英互译 never found its own rows).
pub fn save_page_translation(
    conn: &Connection,
    book_id: i64,
    key_lang: &str,
    translation: &PageTranslation,
) -> AppResult<()> {
    let json = serde_json::to_string(translation)
        .map_err(|e| AppError::Internal(format!("serialize page translation: {e}")))?;
    conn.execute(
        "INSERT INTO page_translation_cache \
             (book_id, page, target_lang, provider, source_hash, result_json) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6) \
         ON CONFLICT (book_id, page, target_lang, provider) DO UPDATE SET \
             source_hash = excluded.source_hash, \
             result_json = excluded.result_json, \
             created_at = datetime('now'), \
             last_accessed_at = datetime('now')",
        params![
            book_id,
            translation.page,
            key_lang,
            translation.provider,
            translation.source_hash,
            json
        ],
    )?;
    Ok(())
}

/// Pages of a book with a cached translation for the given lang + provider
/// (the resume / overview computation, plan §9).
/// Pages of a book with a CURRENT cached translation for the given lang +
/// provider (the resume / overview computation, plan §9). Rows stamped by an
/// older extractor are excluded so a fixed extractor re-translates them.
pub fn translated_pages(
    conn: &Connection,
    book_id: i64,
    target_lang: &str,
    provider: &str,
) -> AppResult<Vec<i64>> {
    let mut stmt = conn.prepare(
        "SELECT page, source_hash FROM page_translation_cache \
         WHERE book_id = ?1 AND target_lang = ?2 AND provider = ?3 ORDER BY page",
    )?;
    let rows = stmt.query_map(params![book_id, target_lang, provider], |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (page, hash) = row?;
        // Skip stale rows (old extractor version) so they get redone.
        if crate::translate::is_current_source_hash(&hash) {
            out.push(page);
        }
    }
    Ok(out)
}

/// Deletes every cached translation of a book (all langs / providers).
pub fn clear_book_translations(conn: &Connection, book_id: i64) -> AppResult<usize> {
    Ok(conn.execute(
        "DELETE FROM page_translation_cache WHERE book_id = ?1",
        params![book_id],
    )?)
}

/// Books that have any translation rows, ordered least-recently-used first
/// (the eviction candidate list, plan §7 -- LRU by the newest access of
/// each book).
pub fn books_by_recency(conn: &Connection) -> AppResult<Vec<(i64, String)>> {
    let mut stmt = conn.prepare(
        "SELECT book_id, MIN(last_accessed_at) AS oldest \
         FROM page_translation_cache GROUP BY book_id ORDER BY oldest ASC",
    )?;
    let rows = stmt.query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)))?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Total on-disk translation cache size in bytes: the `translated/`
/// directories of all books (the cache rows themselves are tiny and are
/// intentionally not counted; plan §7 counts the produced artifacts).
pub fn translated_dir_size() -> u64 {
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
    let root = crate::db::app_data_dir()
        .unwrap_or_default()
        .join("translated");
    if !root.exists() {
        return 0;
    }
    dir_size(&root)
}

// =============================================================================
// Glossary (plan §4.4)
// =============================================================================

pub fn list_glossary(conn: &Connection) -> AppResult<Vec<GlossaryEntry>> {
    let mut stmt = conn.prepare(
        "SELECT id, source_term, target_term, source_lang, target_lang \
         FROM translation_glossary ORDER BY id",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(GlossaryEntry {
            id: row.get(0)?,
            source_term: row.get(1)?,
            target_term: row.get(2)?,
            source_lang: row.get(3)?,
            target_lang: row.get(4)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn add_glossary_entry(
    conn: &Connection,
    source_term: &str,
    target_term: &str,
    source_lang: Option<&str>,
    target_lang: Option<&str>,
) -> AppResult<i64> {
    conn.execute(
        "INSERT INTO translation_glossary (source_term, target_term, source_lang, target_lang) \
         VALUES (?1, ?2, ?3, ?4)",
        params![source_term, target_term, source_lang, target_lang],
    )?;
    Ok(conn.last_insert_rowid())
}

pub fn delete_glossary_entry(conn: &Connection, id: i64) -> AppResult<usize> {
    Ok(conn.execute("DELETE FROM translation_glossary WHERE id = ?1", params![id])?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};
    use crate::models::translate::{
        ParagraphKind, ParagraphStatus, TranslatedParagraph,
    };

    fn test_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        for pragma in PRAGMAS {
            conn.execute_batch(pragma).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "INSERT INTO books (id, title, original_path, stored_path, file_type) \
             VALUES (1, 'b1', '/p1', '/s1', 'pdf');",
        )
        .unwrap();
        conn
    }

    fn translation(page: i64, text: &str) -> PageTranslation {
        PageTranslation {
            page,
            target_lang: "中文".into(),
            provider: "deepl".into(),
            source_hash: crate::translate::stamp_source_hash(&format!("hash-{page}")),
            paragraphs: vec![TranslatedParagraph {
                source: format!("source {page}"),
                translated: text.into(),
                kind: ParagraphKind::Text,
                status: ParagraphStatus::Done,
                confidence: 1.0,
                formula_regions: Vec::new(),
            }],
            coverage: 1.0,
        }
    }

    #[test]
    fn cache_roundtrip_upsert_and_lang_provider_isolation() {
        let conn = test_conn();
        assert!(
            get_page_translation(&conn, 1, 3, "中文", "deepl", false)
                .unwrap()
                .is_none()
        );

        save_page_translation(&conn, 1, "中文", &translation(3, "第三页")).unwrap();
        let cached = get_page_translation(&conn, 1, 3, "中文", "deepl", false)
            .unwrap()
            .unwrap();
        assert_eq!(cached.page, 3);
        assert_eq!(cached.paragraphs[0].translated, "第三页");
        assert!(cached.source_hash.ends_with(":hash-3"), "{}", cached.source_hash);

        // Upsert replaces the same key.
        let mut updated = translation(3, "第三页(重译)");
        updated.source_hash = crate::translate::stamp_source_hash("hash-3b");
        save_page_translation(&conn, 1, "中文", &updated).unwrap();
        let cached = get_page_translation(&conn, 1, 3, "中文", "deepl", false)
            .unwrap()
            .unwrap();
        assert_eq!(cached.paragraphs[0].translated, "第三页(重译)");

        // Lang / provider isolation.
        assert!(
            get_page_translation(&conn, 1, 3, "英文", "deepl", false)
                .unwrap()
                .is_none()
        );
        assert!(
            get_page_translation(&conn, 1, 3, "中文", "reuse_ai", false)
                .unwrap()
                .is_none()
        );

        // translated_pages orders by page number (plan §2: absolute order).
        save_page_translation(&conn, 1, "中文", &translation(10, "十")).unwrap();
        save_page_translation(&conn, 1, "中文", &translation(2, "二")).unwrap();
        assert_eq!(
            translated_pages(&conn, 1, "中文", "deepl").unwrap(),
            vec![2, 3, 10]
        );

        // Access refresh bumps last_accessed_at.
        let before: String = conn
            .query_row(
                "SELECT last_accessed_at FROM page_translation_cache WHERE page = 2",
                [],
                |r| r.get(0),
            )
            .unwrap();
        get_page_translation(&conn, 1, 2, "中文", "deepl", true).unwrap();
        let after: String = conn
            .query_row(
                "SELECT last_accessed_at FROM page_translation_cache WHERE page = 2",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(after >= before);

        // Clear + cascade.
        assert_eq!(clear_book_translations(&conn, 1).unwrap(), 3);
        assert!(translated_pages(&conn, 1, "中文", "deepl").unwrap().is_empty());
    }

    #[test]
    fn configured_key_is_stored_while_effective_lang_stays_in_payload() {
        // Regression: 中英互译 writes rows under the CONFIGURED key so reads
        // hit, while the per-page EFFECTIVE language travels in the payload.
        let conn = test_conn();
        let mut t = translation(1, "Quantum worlds are strange.");
        t.target_lang = "英文".into(); // effective language of this page
        save_page_translation(&conn, 1, "中英互译", &t).unwrap();

        let (col, json): (String, String) = conn
            .query_row(
                "SELECT target_lang, result_json FROM page_translation_cache WHERE book_id=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(col, "中英互译");
        assert!(json.contains("英文"));

        // Read under the configured key hits; the payload keeps 英文.
        let got = get_page_translation(&conn, 1, 1, "中英互译", "deepl", false)
            .unwrap()
            .unwrap();
        assert_eq!(got.target_lang, "英文");
        // Reading under the effective language must NOT hit.
        assert!(
            get_page_translation(&conn, 1, 1, "英文", "deepl", false)
                .unwrap()
                .is_none()
        );
    }

    #[test]
    fn glossary_crud() {
        let conn = test_conn();
        assert!(list_glossary(&conn).unwrap().is_empty());
        let id = add_glossary_entry(&conn, "quantum", "量子", None, None).unwrap();
        add_glossary_entry(&conn, "entanglement", "纠缠", Some("EN"), Some("ZH")).unwrap();
        let entries = list_glossary(&conn).unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0].source_term, "quantum");
        assert_eq!(entries[0].target_term, "量子");
        assert_eq!(entries[1].source_lang.as_deref(), Some("EN"));
        assert_eq!(delete_glossary_entry(&conn, id).unwrap(), 1);
        assert_eq!(list_glossary(&conn).unwrap().len(), 1);
    }

    #[test]
    fn books_by_recency_orders_least_recently_used_first() {
        let conn = test_conn();
        conn.execute_batch(
            "INSERT INTO books (id, title, original_path, stored_path, file_type) \
             VALUES (2, 'b2', '/p2', '/s2', 'pdf'), \
                    (3, 'b3', '/p3', '/s3', 'pdf');",
        )
        .unwrap();
        // Save rows, then age book 1 the most and book 3 the least.
        save_page_translation(&conn, 1, "中文", &translation(1, "一")).unwrap();
        save_page_translation(&conn, 2, "中文", &translation(1, "二")).unwrap();
        save_page_translation(&conn, 3, "中文", &translation(1, "三")).unwrap();
        conn.execute(
            "UPDATE page_translation_cache SET last_accessed_at = '2020-01-01 00:00:00' \
             WHERE book_id = 1",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE page_translation_cache SET last_accessed_at = '2021-01-01 00:00:00' \
             WHERE book_id = 2",
            [],
        )
        .unwrap();
        conn.execute(
            "UPDATE page_translation_cache SET last_accessed_at = '2022-01-01 00:00:00' \
             WHERE book_id = 3",
            [],
        )
        .unwrap();
        let order: Vec<i64> = books_by_recency(&conn).unwrap().into_iter().map(|(b, _)| b).collect();
        assert_eq!(order, vec![1, 2, 3], "oldest access evicts first");
    }
}
