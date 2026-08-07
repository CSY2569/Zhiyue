//! `categories` table repository (FEATURES 9.1.9 / 2.8, M1).
//!
//! Categories are lightweight user-defined classifications. Deleting a category
//! sets `books.category_id` to NULL (the FK uses `ON DELETE SET NULL`), so no
//! explicit book-update query is needed here.

use rusqlite::{params, Connection, Row};

use crate::error::{AppError, AppResult};
use crate::models::book::Category;

const SELECT_COLS: &str = "id, name, sort_order, created_at";

fn row_to_category(row: &Row) -> rusqlite::Result<Category> {
    Ok(Category {
        id: row.get(0)?,
        name: row.get(1)?,
        sort_order: row.get(2)?,
        created_at: row.get(3)?,
    })
}

/// List all categories ordered by `sort_order` then `created_at`.
pub fn list(conn: &Connection) -> AppResult<Vec<Category>> {
    let mut stmt =
        conn.prepare(&format!("SELECT {SELECT_COLS} FROM categories ORDER BY sort_order, created_at"))?;
    let rows = stmt.query_map([], row_to_category)?;
    let mut cats = Vec::new();
    for row in rows {
        cats.push(row?);
    }
    Ok(cats)
}

/// Create a new category. The `sort_order` is set to one past the current max
/// so new categories appear last. Returns `Err` if the name is already taken
/// (UNIQUE constraint).
pub fn create(conn: &Connection, name: &str) -> AppResult<Category> {
    let next_order: i64 = conn
        .query_row("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories", [], |row| {
            row.get(0)
        })
        .unwrap_or(0);
    conn.execute(
        "INSERT INTO categories (name, sort_order) VALUES (?1, ?2)",
        params![name, next_order],
    )?;
    let id = conn.last_insert_rowid();
    conn.query_row(
        &format!("SELECT {SELECT_COLS} FROM categories WHERE id = ?1"),
        params![id],
        row_to_category,
    )
    .map_err(|e| AppError::Database(e.to_string()))
}

/// Rename a category. Returns `true` if a row was updated, `false` if the id
/// was not found or the new name collides with an existing one.
pub fn rename(conn: &Connection, id: i64, name: &str) -> AppResult<bool> {
    let changes = conn.execute(
        "UPDATE categories SET name = ?1 WHERE id = ?2",
        params![name, id],
    )?;
    Ok(changes > 0)
}

/// Delete a category by id. Books referencing it fall back to unclassified
/// (`category_id` becomes NULL via the FK's `ON DELETE SET NULL` rule).
/// Returns `true` if a row was removed.
pub fn delete(conn: &Connection, id: i64) -> AppResult<bool> {
    let changes = conn.execute("DELETE FROM categories WHERE id = ?1", params![id])?;
    Ok(changes > 0)
}
