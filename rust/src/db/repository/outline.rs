//! CRUD for user edits of a document outline (v12).
//!
//! The rows are merged over the pdfium outline by
//! [`crate::pdf::outline_edit::merge`]; this module only stores them.

use rusqlite::Connection;

use crate::error::AppResult;
use crate::pdf::outline_edit::OutlineOverride;

pub fn list(conn: &Connection, book_id: i64) -> AppResult<Vec<OutlineOverride>> {
    let mut stmt = conn.prepare(
        "SELECT entry_key, parent_key, title, page, order_index, hidden
         FROM book_outline_overrides WHERE book_id = ?1",
    )?;
    let rows = stmt.query_map(rusqlite::params![book_id], |row| {
        Ok(OutlineOverride {
            entry_key: row.get(0)?,
            parent_key: row.get(1)?,
            title: row.get(2)?,
            page: row.get(3)?,
            order_index: row.get(4)?,
            hidden: row.get::<_, i64>(5)? != 0,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Insert or replace one entry. Returns whether the row is now present.
pub fn upsert(conn: &Connection, book_id: i64, o: &OutlineOverride) -> AppResult<bool> {
    conn.execute(
        "INSERT INTO book_outline_overrides
             (book_id, entry_key, parent_key, title, page, order_index, hidden, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, datetime('now'))
         ON CONFLICT(book_id, entry_key) DO UPDATE SET
             parent_key = excluded.parent_key,
             title = excluded.title,
             page = excluded.page,
             order_index = excluded.order_index,
             hidden = excluded.hidden,
             updated_at = datetime('now')",
        rusqlite::params![
            book_id,
            o.entry_key,
            o.parent_key,
            o.title,
            o.page,
            o.order_index,
            if o.hidden { 1 } else { 0 },
        ],
    )?;
    Ok(true)
}

pub fn delete(conn: &Connection, book_id: i64, entry_key: &str) -> AppResult<bool> {
    let removed = conn.execute(
        "DELETE FROM book_outline_overrides WHERE book_id = ?1 AND entry_key = ?2",
        rusqlite::params![book_id, entry_key],
    )?;
    Ok(removed > 0)
}

/// Drop every edit for [book_id] ("restore the document outline").
pub fn delete_all(conn: &Connection, book_id: i64) -> AppResult<usize> {
    let removed = conn.execute(
        "DELETE FROM book_outline_overrides WHERE book_id = ?1",
        rusqlite::params![book_id],
    )?;
    Ok(removed)
}
