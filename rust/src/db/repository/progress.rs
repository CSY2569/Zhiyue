//! `reading_progress` table repository (FEATURES 9.1.2 / 3.3.4, M2).
//!
//! One row per book (`book_id` is the primary key). The row is upserted on
//! save; reading progress is cascade-deleted when a book is removed (FK).

use rusqlite::{params, Connection, Row};

use crate::error::{AppError, AppResult};
use crate::models::progress::{ReadingProgress, ViewMode};

fn row_to_progress(row: &Row) -> rusqlite::Result<ReadingProgress> {
    let view_mode_str: String = row.get(3)?;
    Ok(ReadingProgress {
        book_id: row.get(0)?,
        page: row.get(1)?,
        zoom: row.get(2)?,
        view_mode: ViewMode::from_db_str(&view_mode_str).unwrap_or(ViewMode::Single),
        updated_at: row.get(4)?,
    })
}

/// Load the saved reading position for a book. Returns `None` if no progress
/// has been saved yet (first open).
pub fn get(conn: &Connection, book_id: i64) -> AppResult<Option<ReadingProgress>> {
    let mut stmt = conn.prepare(
        "SELECT book_id, page, zoom, view_mode, updated_at \
         FROM reading_progress WHERE book_id = ?1",
    )?;
    let mut rows = stmt.query_map(params![book_id], row_to_progress)?;
    match rows.next() {
        Some(row) => Ok(Some(row?)),
        None => Ok(None),
    }
}

/// Upsert the reading position (FEATURES 3.3.4). Called debounced from the
/// viewer when the page or zoom changes.
pub fn save(
    conn: &Connection,
    book_id: i64,
    page: i64,
    zoom: f64,
    view_mode: ViewMode,
) -> AppResult<()> {
    let changed = conn.execute(
        "INSERT INTO reading_progress (book_id, page, zoom, view_mode, updated_at) \
         VALUES (?1, ?2, ?3, ?4, datetime('now')) \
         ON CONFLICT(book_id) DO UPDATE SET \
            page = excluded.page, \
            zoom = excluded.zoom, \
            view_mode = excluded.view_mode, \
            updated_at = excluded.updated_at",
        params![book_id, page, zoom, view_mode.as_str()],
    )?;
    if changed == 0 {
        return Err(AppError::Internal("progress save affected 0 rows".into()));
    }
    Ok(())
}
