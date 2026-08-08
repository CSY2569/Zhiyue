//! Full-text search persistence (FEATURES 3.5, M6).
//!
//! One row per (book_id, page): `raw_text` holds the jieba-segmented text
//! the FTS5 table indexes, `original_text` the raw page text for snippets
//! and hit location. The schema triggers keep `page_text_fts` (external
//! content) in sync, so the books-row FK cascade also removes FTS entries.
//! A "ready" marker in `settings` distinguishes fully built books from
//! partially indexed ones (e.g. a build interrupted by a crash).

use rusqlite::Connection;

use crate::error::AppResult;
use crate::search::tokenize;

/// One search hit: the book, the 0-indexed page, and a context snippet
/// around the first occurrence of the query.
#[derive(Debug, Clone, PartialEq)]
pub struct SearchHit {
    pub book_id: i64,
    pub page: i64,
    pub snippet: String,
}

const READY_KEY: &str = "search_index_ready_";
const FAILED_KEY: &str = "search_index_failed_";

/// Upsert one page into the index. [original] is the raw page text
/// (snippets / hit location); [segmented] the jieba-segmented form the FTS
/// indexes. The UPDATE arm re-fires the `au` trigger (delete + insert).
pub fn index_page(
    conn: &Connection,
    book_id: i64,
    page: i64,
    source: &str,
    original: &str,
    segmented: &str,
) -> AppResult<()> {
    conn.execute(
        "INSERT INTO page_text_index (book_id, page, source, raw_text, original_text) \
         VALUES (?1, ?2, ?3, ?4, ?5) \
         ON CONFLICT (book_id, page) DO UPDATE SET \
             source = excluded.source, raw_text = excluded.raw_text, \
             original_text = excluded.original_text, \
             indexed_at = datetime('now')",
        rusqlite::params![book_id, page, source, segmented, original],
    )?;
    Ok(())
}

/// Library-wide full-text search (FEATURES 3.5.2): hits ordered by book
/// then page, capped at [limit]. The query is segmented like the index, so
/// token boundaries match.
pub fn search(conn: &Connection, query: &str, limit: i64) -> AppResult<Vec<SearchHit>> {
    let expr = match_expr(query);
    if expr.is_empty() {
        return Ok(Vec::new());
    }
    let mut stmt = conn.prepare(
        "SELECT p.book_id, p.page, p.original_text \
         FROM page_text_fts f \
         JOIN page_text_index p ON p.rowid = f.rowid \
         WHERE page_text_fts MATCH ?1 \
         ORDER BY p.book_id, p.page \
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(rusqlite::params![expr, limit], |r| {
        Ok((
            r.get::<_, i64>(0)?,
            r.get::<_, i64>(1)?,
            r.get::<_, Option<String>>(2)?,
        ))
    })?;
    let mut hits = Vec::new();
    for row in rows {
        let (book_id, page, original) = row?;
        hits.push(SearchHit {
            book_id,
            page,
            snippet: snippet(&original.unwrap_or_default(), query),
        });
    }
    Ok(hits)
}

/// The FTS5 MATCH expression: each token double-quoted so operator
/// characters in the query cannot inject FTS syntax (quotes stripped;
/// tokens emptied by the strip are dropped).
fn match_expr(query: &str) -> String {
    tokenize(query)
        .split_whitespace()
        .map(|t| t.replace('"', ""))
        .filter(|t| !t.is_empty())
        .map(|t| format!("\"{t}\""))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Context window around the first occurrence of [query] in [text]
/// (±SNIPPET_HALF chars, ellipses when truncated). Falls back to the
/// query's first token when the verbatim string is absent (tokenizer
/// boundary differences between query and page text).
fn snippet(text: &str, query: &str) -> String {
    const SNIPPET_HALF: usize = 30;
    let chars: Vec<char> = text.trim().chars().collect();
    if chars.is_empty() {
        return String::new();
    }
    let q: Vec<char> = query.trim().chars().collect();
    let mut hit = find_subseq(&chars, &q);
    if hit.is_none() {
        hit = tokenize(query)
            .split_whitespace()
            .next()
            .map(|t| t.chars().collect::<Vec<_>>())
            .and_then(|t| find_subseq(&chars, &t));
    }
    let Some(hit) = hit else {
        // No verbatim occurrence: head of the text as a plain context.
        let take = chars.len().min(SNIPPET_HALF * 2);
        return chars[..take].iter().collect();
    };
    let start = hit.saturating_sub(SNIPPET_HALF);
    let end = (hit + q.len() + SNIPPET_HALF).min(chars.len());
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.extend(&chars[start..end]);
    if end < chars.len() {
        out.push('…');
    }
    out
}

/// First index of [needle] in [haystack], or None.
fn find_subseq(haystack: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

/// Mark the book's index as fully built (settings KV, survives restarts).
pub fn mark_ready(conn: &Connection, book_id: i64, pages: i64) -> AppResult<()> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) \
         ON CONFLICT (key) DO UPDATE SET value = excluded.value, \
             updated_at = datetime('now')",
        rusqlite::params![
            format!("{READY_KEY}{book_id}"),
            format!("{{\"pages\":{pages}}}")
        ],
    )?;
    Ok(())
}

/// Mark the book's index build as failed (unreadable document, e.g. a
/// corrupt PDF): a terminal state so ensure_book_index stops retrying on
/// every library visit. Cleared by re-importing the book.
pub fn mark_failed(conn: &Connection, book_id: i64) -> AppResult<()> {
    conn.execute(
        "INSERT INTO settings (key, value) VALUES (?1, ?2) \
         ON CONFLICT (key) DO UPDATE SET value = excluded.value, \
             updated_at = datetime('now')",
        rusqlite::params![format!("{FAILED_KEY}{book_id}"), "{}"],
    )?;
    Ok(())
}

/// Whether a previous index build failed for this book (unreadable file).
pub fn is_failed(conn: &Connection, book_id: i64) -> bool {
    conn.query_row(
        "SELECT 1 FROM settings WHERE key = ?1",
        rusqlite::params![format!("{FAILED_KEY}{book_id}")],
        |_| Ok(()),
    )
    .is_ok()
}

/// Drop every search marker of the book (deletion / re-import reset).
pub fn clear_markers(conn: &Connection, book_id: i64) -> AppResult<()> {
    conn.execute(
        "DELETE FROM settings WHERE key IN (?1, ?2)",
        rusqlite::params![
            format!("{READY_KEY}{book_id}"),
            format!("{FAILED_KEY}{book_id}")
        ],
    )?;
    Ok(())
}

/// Whether the book's index was fully built (vs. partially indexed).
pub fn is_ready(conn: &Connection, book_id: i64) -> bool {
    conn.query_row(
        "SELECT 1 FROM settings WHERE key = ?1",
        rusqlite::params![format!("{READY_KEY}{book_id}")],
        |_| Ok(()),
    )
    .is_ok()
}

/// Whether the book has any indexed page (OCR-only books become searchable
/// as pages are scanned, without a full build).
pub fn has_rows(conn: &Connection, book_id: i64) -> bool {
    conn.query_row(
        "SELECT 1 FROM page_text_index WHERE book_id = ?1 LIMIT 1",
        rusqlite::params![book_id],
        |_| Ok(()),
    )
    .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};

    /// In-memory DB with the full schema (incl. FTS triggers).
    fn mem_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        for pragma in PRAGMAS {
            conn.execute_batch(pragma).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn
    }

    fn insert_book(conn: &Connection, id: i64, title: &str) {
        conn.execute(
            "INSERT INTO books (id, title, original_path, stored_path, file_type) \
             VALUES (?1, ?2, ?3, ?3, 'pdf')",
            rusqlite::params![id, title, format!("/x{id}.pdf")],
        )
        .unwrap();
    }

    #[test]
    fn index_page_is_searchable_and_upserts() {
        let conn = mem_db();
        insert_book(&conn, 1, "测试书");

        index_page(&conn, 1, 0, "pdf", "量子计算入门", "量子 计算 入门").unwrap();
        index_page(&conn, 1, 1, "pdf", "深度学习基础", "深度 学习 基础").unwrap();

        let hits = search(&conn, "量子", 100).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].book_id, 1);
        assert_eq!(hits[0].page, 0);
        assert!(hits[0].snippet.contains("量子"), "{}", hits[0].snippet);

        // Re-indexing the same page replaces its text (scan re-run).
        index_page(&conn, 1, 0, "ocr", "量子力学导论", "量子 力学 导论").unwrap();
        let hits = search(&conn, "力学", 100).unwrap();
        assert_eq!(hits.len(), 1);
        let hits = search(&conn, "入门", 100).unwrap();
        assert!(hits.is_empty(), "stale text must be replaced");
    }

    #[test]
    fn chinese_search_matches_segmented_tokens() {
        let conn = mem_db();
        insert_book(&conn, 2, "算法");
        index_page(
            &conn,
            2,
            0,
            "pdf",
            "本文介绍排序算法与数据结构",
            "本文 介绍 排序 算法 与 数据 结构",
        )
        .unwrap();
        let hits = search(&conn, "算法", 10).unwrap();
        assert_eq!(hits.len(), 1);
    }

    #[test]
    fn book_delete_cascades_fts_entries() {
        let conn = mem_db();
        insert_book(&conn, 3, "待删");
        index_page(&conn, 3, 0, "pdf", "内容", "内容").unwrap();
        assert_eq!(search(&conn, "内容", 10).unwrap().len(), 1);
        conn.execute("DELETE FROM books WHERE id = 3", []).unwrap();
        assert!(search(&conn, "内容", 10).unwrap().is_empty());
    }

    #[test]
    fn match_expr_quotes_tokens_and_strips_quotes() {
        assert_eq!(match_expr("量子 计算"), "\"量子\" \"计算\"");
        // A quote in the query must not break out of the quoted token.
        assert_eq!(match_expr("a\" OR b"), "\"a\" \"OR\" \"b\"");
        assert_eq!(match_expr("   "), "");
    }

    #[test]
    fn snippet_windows_around_the_hit() {
        // 40 chars of filler before the hit, 40+ after: both sides must be
        // truncated by the ±30 window.
        let text = format!(
            "{}摘要窗口{}",
            "一二三四五六七八九十".repeat(4),
            "甲乙丙丁戊己庚辛壬癸".repeat(4)
        );
        let s = snippet(&text, "摘要窗口");
        assert!(s.contains("摘要窗口"), "{s}");
        assert!(s.starts_with('…'), "{s}");
        assert!(s.ends_with('…'), "{s}");
        assert!(s.len() < text.len(), "{s}");
        // No occurrence -> plain head window.
        let s = snippet(&text, "不存在");
        assert!(!s.contains("不存在"), "{s}");
    }

    #[test]
    fn ready_and_failed_markers_roundtrip() {
        let conn = mem_db();
        assert!(!is_ready(&conn, 9));
        assert!(!is_failed(&conn, 9));
        mark_ready(&conn, 9, 12).unwrap();
        assert!(is_ready(&conn, 9));
        clear_markers(&conn, 9).unwrap();
        assert!(!is_ready(&conn, 9));

        mark_failed(&conn, 9).unwrap();
        assert!(is_failed(&conn, 9));
        assert!(!is_ready(&conn, 9));
        // Re-import (clear_markers) resets both states.
        clear_markers(&conn, 9).unwrap();
        assert!(!is_failed(&conn, 9));
        assert!(!has_rows(&conn, 9));
    }
}
