//! `books` table repository (FEATURES 9.1.1, M1).
//!
//! Pure CRUD over a borrowed `&Connection`; the caller (api layer) owns the
//! global lock and any file IO. Row mapping centralizes the `favorite`
//! INTEGER↔bool and `file_type` TEXT↔BookType conversions that rusqlite cannot
//! derive automatically.

use rusqlite::{params, Connection, Row};

use crate::error::{AppError, AppResult};
use crate::models::book::{Book, BookType};

/// Columns selected from `books`, in the order `row_to_book` expects.
const SELECT_COLS: &str = "id, title, original_path, stored_path, file_type, \
     page_count, cover_path, favorite, category_id, last_opened_at, imported_at";

/// Map a `rusqlite::Row` to a `Book`, applying the bool/enum conversions.
fn row_to_book(row: &Row) -> rusqlite::Result<Book> {
    let favorite_int: i64 = row.get(7)?;
    let file_type_str: String = row.get(4)?;
    Ok(Book {
        id: row.get(0)?,
        title: row.get(1)?,
        original_path: row.get(2)?,
        stored_path: row.get(3)?,
        file_type: BookType::from_db_str(&file_type_str).unwrap_or(BookType::Image),
        page_count: row.get(5)?,
        cover_path: row.get(6)?,
        favorite: favorite_int != 0,
        category_id: row.get(8)?,
        last_opened_at: row.get(9)?,
        imported_at: row.get(10)?,
    })
}

/// Parameters for inserting a new book row. `original_path` is the de-dup key.
pub struct NewBook {
    pub title: String,
    pub original_path: String,
    pub stored_path: String,
    pub file_type: BookType,
    pub page_count: i64,
    pub cover_path: Option<String>,
}

/// List all books, most-recently-opened first (FEATURES 2.3).
/// Unopened books sort after opened ones, newest-imported first among ties.
pub fn list(conn: &Connection) -> AppResult<Vec<Book>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLS} FROM books \
         ORDER BY last_opened_at IS NULL, last_opened_at DESC, imported_at DESC"
    ))?;
    let rows = stmt.query_map([], row_to_book)?;
    let mut books = Vec::new();
    for row in rows {
        books.push(row?);
    }
    Ok(books)
}

/// Fetch a single book by id. Returns `None` if not found.
pub fn get(conn: &Connection, id: i64) -> AppResult<Option<Book>> {
    let mut stmt = conn.prepare(&format!("SELECT {SELECT_COLS} FROM books WHERE id = ?1"))?;
    let mut rows = stmt.query_map(params![id], row_to_book)?;
    match rows.next() {
        Some(row) => Ok(Some(row?)),
        None => Ok(None),
    }
}

/// Look up a book by its original filesystem path -- the de-dup key (FEATURES 2.1).
pub fn find_by_original_path(conn: &Connection, path: &str) -> AppResult<Option<Book>> {
    let mut stmt =
        conn.prepare(&format!("SELECT {SELECT_COLS} FROM books WHERE original_path = ?1"))?;
    let mut rows = stmt.query_map(params![path], row_to_book)?;
    match rows.next() {
        Some(row) => Ok(Some(row?)),
        None => Ok(None),
    }
}

/// Insert a new book row and return the inserted record. Caller must ensure
/// `original_path` is not already present (call `find_by_original_path` first).
pub fn insert(conn: &Connection, params: &NewBook) -> AppResult<Book> {
    conn.execute(
        "INSERT INTO books (title, original_path, stored_path, file_type, page_count, cover_path) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params![
            params.title,
            params.original_path,
            params.stored_path,
            params.file_type.as_str(),
            params.page_count,
            params.cover_path,
        ],
    )?;
    let id = conn.last_insert_rowid();
    get(conn, id)?
        .ok_or_else(|| AppError::Internal("insert succeeded but row not found".into()))
}

/// Delete a book by id. Returns `true` if a row was removed.
/// Child rows (progress, annotations, OCR cache, text index) cascade via FK.
pub fn delete(conn: &Connection, id: i64) -> AppResult<bool> {
    let changes = conn.execute("DELETE FROM books WHERE id = ?1", params![id])?;
    Ok(changes > 0)
}

/// Toggle the favorite flag and return the updated row, or `None` if the book
/// was not found.
pub fn set_favorite(conn: &Connection, id: i64, fav: bool) -> AppResult<Option<Book>> {
    let changes = conn.execute(
        "UPDATE books SET favorite = ?1 WHERE id = ?2",
        params![fav as i64, id],
    )?;
    if changes == 0 {
        return Ok(None);
    }
    get(conn, id)
}

/// Stamp `last_opened_at` to now (FEATURES 2.3: most-recently-opened sort).
/// No-op if the book does not exist.
pub fn touch_last_opened(conn: &Connection, id: i64) -> AppResult<()> {
    conn.execute(
        "UPDATE books SET last_opened_at = datetime('now') WHERE id = ?1",
        params![id],
    )?;
    Ok(())
}

/// Assign or clear a book's category (FEATURES 2.8). Pass `None` to unclassify.
/// The FK constraint ensures invalid category ids are rejected.
pub fn set_category(
    conn: &Connection,
    book_id: i64,
    category_id: Option<i64>,
) -> AppResult<()> {
    conn.execute(
        "UPDATE books SET category_id = ?1 WHERE id = ?2",
        params![category_id, book_id],
    )?;
    Ok(())
}

/// Update the page count for a book (M2: populated via pdfium after import).
pub fn update_page_count(conn: &Connection, id: i64, page_count: i64) -> AppResult<()> {
    conn.execute(
        "UPDATE books SET page_count = ?1 WHERE id = ?2",
        params![page_count, id],
    )?;
    Ok(())
}

/// Update the cover thumbnail path for a book (M2: rendered via pdfium).
pub fn update_cover(conn: &Connection, id: i64, cover_path: Option<String>) -> AppResult<()> {
    conn.execute(
        "UPDATE books SET cover_path = ?1 WHERE id = ?2",
        params![cover_path, id],
    )?;
    Ok(())
}
