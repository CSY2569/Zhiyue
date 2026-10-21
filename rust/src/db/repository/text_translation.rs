//! Per-block text translation cache (Android v1).
//!
//! `page_text_translation` stores one row per (book, page, block index, target
//! language). Unlike the desktop engine, which persists its caches as files
//! under `retain_output/`, the mobile path is stateless apart from SQLite:
//! every block is addressed by its own row, so a partially translated page is
//! resumable block by block.
//!
//! Invalidation is content-based: `source_hash` covers the block's source
//! text, and `model` covers the LLM. A changed paragraph or a new model makes
//! the row stale without deleting anything else.

use rusqlite::params;

use crate::error::AppResult;
use crate::models::translate::{TextBlockStatus, TranslatedTextBlock};

/// One cached block row.
#[derive(Debug, Clone)]
pub struct CachedBlock {
    pub block_index: i64,
    pub target_lang: String,
    pub model: String,
    pub source_hash: String,
    pub kind: String,
    pub sub_type: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub source_text: String,
    pub translated_text: String,
    pub status: TextBlockStatus,
}

/// A block ready to be written.
#[derive(Debug, Clone)]
pub struct BlockRow<'a> {
    pub block_index: i64,
    pub kind: &'a str,
    pub sub_type: &'a str,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub source_text: &'a str,
    pub translated_text: &'a str,
    pub status: TextBlockStatus,
    pub source_hash: &'a str,
}

/// All cached blocks of one page under a target language.
pub fn get_page_blocks(
    conn: &rusqlite::Connection,
    book_id: i64,
    page: i64,
    target_lang: &str,
) -> AppResult<Vec<CachedBlock>> {
    let mut stmt = conn.prepare(
        "SELECT block_index, target_lang, model, source_hash, kind, sub_type, \
                x, y, w, h, source_text, translated_text, status \
         FROM page_text_translation \
         WHERE book_id = ?1 AND page = ?2 AND target_lang = ?3 \
         ORDER BY block_index ASC",
    )?;
    let rows = stmt.query_map(params![book_id, page, target_lang], |row| {
        let status: String = row.get(12)?;
        Ok(CachedBlock {
            block_index: row.get(0)?,
            target_lang: row.get(1)?,
            model: row.get(2)?,
            source_hash: row.get(3)?,
            kind: row.get(4)?,
            sub_type: row.get(5)?,
            x: row.get(6)?,
            y: row.get(7)?,
            w: row.get(8)?,
            h: row.get(9)?,
            source_text: row.get(10)?,
            translated_text: row.get(11)?,
            status: TextBlockStatus::from_db_str(&status).unwrap_or(TextBlockStatus::Failed),
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Replaces every block row of a page in one transaction.
///
/// Whole-page replacement (rather than per-block upsert) keeps the cache
/// consistent when block segmentation changes after an OCR correction: stale
/// indices for blocks that no longer exist are dropped.
pub fn replace_page_blocks(
    conn: &mut rusqlite::Connection,
    book_id: i64,
    page: i64,
    target_lang: &str,
    model: &str,
    blocks: &[BlockRow<'_>],
) -> AppResult<()> {
    let tx = conn.transaction()?;
    tx.execute(
        "DELETE FROM page_text_translation \
         WHERE book_id = ?1 AND page = ?2 AND target_lang = ?3",
        params![book_id, page, target_lang],
    )?;
    {
        let mut stmt = tx.prepare(
            "INSERT INTO page_text_translation \
                (book_id, page, block_index, target_lang, model, source_hash, \
                 kind, sub_type, x, y, w, h, source_text, translated_text, status) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
        )?;
        for b in blocks {
            stmt.execute(params![
                book_id,
                page,
                b.block_index,
                target_lang,
                model,
                b.source_hash,
                b.kind,
                b.sub_type,
                b.x,
                b.y,
                b.w,
                b.h,
                b.source_text,
                b.translated_text,
                b.status.as_str(),
            ])?;
        }
    }
    tx.commit()?;
    Ok(())
}

/// Deletes one book's text translations (delete-book cascade / user action).
pub fn clear_book(conn: &rusqlite::Connection, book_id: i64) -> AppResult<usize> {
    let n = conn.execute(
        "DELETE FROM page_text_translation WHERE book_id = ?1",
        params![book_id],
    )?;
    Ok(n)
}

/// How many pages of a book have at least one cached block.
pub fn translated_page_count(
    conn: &rusqlite::Connection,
    book_id: i64,
    target_lang: &str,
) -> AppResult<i64> {
    let n: i64 = conn.query_row(
        "SELECT COUNT(DISTINCT page) FROM page_text_translation \
         WHERE book_id = ?1 AND target_lang = ?2",
        params![book_id, target_lang],
        |row| row.get(0),
    )?;
    Ok(n)
}

/// Convert a cached row into the FFI model (source geometry preserved).
pub fn into_translated(c: CachedBlock, error: Option<String>) -> TranslatedTextBlock {
    TranslatedTextBlock {
        index: c.block_index,
        kind: c.kind,
        sub_type: c.sub_type,
        x: c.x,
        y: c.y,
        w: c.w,
        h: c.h,
        source_text: c.source_text,
        translated_text: c.translated_text,
        status: c.status,
        error,
    }
}

/// Stable content hash for cache invalidation (SHA-256 hex of the text).
pub fn source_hash(text: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(text.as_bytes());
    format!("{:x}", hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};

    fn test_conn() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        for p in PRAGMAS {
            let _ = conn.execute_batch(&p.replace("WAL", "MEMORY"));
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute(
            "INSERT INTO books (title, original_path, stored_path, file_type) \
             VALUES ('t', '/tmp/t.pdf', '/tmp/t.pdf', 'pdf')",
            [],
        )
        .unwrap();
        conn
    }

    #[test]
    fn replace_get_and_clear_round_trip() {
        let mut conn = test_conn();
        let rows = [
            BlockRow {
                block_index: 0,
                kind: "text",
                sub_type: "body",
                x: 0.1,
                y: 0.2,
                w: 0.8,
                h: 0.05,
                source_text: "Hello",
                translated_text: "你好",
                status: TextBlockStatus::Done,
                source_hash: &source_hash("Hello"),
            },
            BlockRow {
                block_index: 1,
                kind: "formula",
                sub_type: "display_formula",
                x: 0.1,
                y: 0.4,
                w: 0.5,
                h: 0.1,
                source_text: "E=mc^2",
                translated_text: "E=mc^2",
                status: TextBlockStatus::Skipped,
                source_hash: &source_hash("E=mc^2"),
            },
        ];
        replace_page_blocks(&mut conn, 1, 3, "中文", "m1", &rows).unwrap();

        let got = get_page_blocks(&conn, 1, 3, "中文").unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].translated_text, "你好");
        assert_eq!(got[1].status, TextBlockStatus::Skipped);

        // A second write replaces, never duplicates.
        replace_page_blocks(&mut conn, 1, 3, "中文", "m1", &rows[..1]).unwrap();
        assert_eq!(get_page_blocks(&conn, 1, 3, "中文").unwrap().len(), 1);

        // Target languages are isolated.
        assert!(get_page_blocks(&conn, 1, 3, "English").unwrap().is_empty());

        assert_eq!(translated_page_count(&conn, 1, "中文").unwrap(), 1);
        assert_eq!(clear_book(&conn, 1).unwrap(), 1);
        assert!(get_page_blocks(&conn, 1, 3, "中文").unwrap().is_empty());
    }
}
