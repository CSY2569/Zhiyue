//! `translation_glossary` repository (M7).
//!
//! The retired built-in pipeline's `page_translation_cache` was dropped in
//! schema v8 (translation moved to the downloadable BabelDOC engine; its
//! artifacts live under `translated/{book_id}/` on disk). Repositories take
//! a borrowed `&Connection` and do no file IO -- the on-disk helpers below
//! are the exception, kept here next to the artifact LRU they serve.

use rusqlite::{params, Connection};

use crate::error::AppResult;
use crate::models::translate::GlossaryEntry;

/// Recursive on-disk size of [dir] in bytes (unreadable entries count as 0).
pub(crate) fn dir_size(dir: &std::path::Path) -> u64 {
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

/// Total on-disk translation cache size in bytes: the `translated/`
/// directories of all books (plan §7 counts the produced artifacts).
pub fn translated_dir_size() -> u64 {
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

    fn test_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        for pragma in PRAGMAS {
            conn.execute_batch(pragma).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn
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
}