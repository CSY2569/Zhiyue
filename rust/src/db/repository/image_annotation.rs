//! `image_annotations` table repository (FEATURES 9.1.10 / §5 image-layer
//! marks, M5).
//!
//! Image-layer marks (brush / shape / sticky / stamp) store a normalized
//! position + rotation plus kind-specific JSON `payload` / `style`. Marks
//! never modify the underlying image; the table only records them. Rows
//! cascade-delete with their book (FK).

use rusqlite::{params, Connection, Row};

use crate::error::{AppError, AppResult};
use crate::models::annotation::{ImageAnnotation, ImageAnnotationKind};

/// Columns selected from `image_annotations`, in the order
/// `row_to_annotation` expects.
const SELECT_COLS: &str = "id, book_id, page, kind, x, y, w, h, rotation, \
     payload, style, created_at";

/// Map a `rusqlite::Row` to an `ImageAnnotation`.
fn row_to_annotation(row: &Row) -> rusqlite::Result<ImageAnnotation> {
    let kind_str: String = row.get(3)?;
    Ok(ImageAnnotation {
        id: row.get(0)?,
        book_id: row.get(1)?,
        page: row.get(2)?,
        kind: ImageAnnotationKind::from_db_str(&kind_str)
            .unwrap_or(ImageAnnotationKind::Brush),
        x: row.get(4)?,
        y: row.get(5)?,
        w: row.get(6)?,
        h: row.get(7)?,
        rotation: row.get(8)?,
        payload: row.get(9)?,
        style: row.get(10)?,
        created_at: row.get(11)?,
    })
}

/// List all image-layer marks of a book, ordered by page then creation
/// (FEATURES 5.5: the layer panel groups them by page).
pub fn list(conn: &Connection, book_id: i64) -> AppResult<Vec<ImageAnnotation>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLS} FROM image_annotations \
         WHERE book_id = ?1 ORDER BY page, created_at, id"
    ))?;
    let rows = stmt.query_map(params![book_id], row_to_annotation)?;
    let mut anns = Vec::new();
    for row in rows {
        anns.push(row?);
    }
    Ok(anns)
}

/// Insert a new image-layer mark; returns the new row id.
// One param per persisted column keeps call sites (api.rs) explicit.
#[allow(clippy::too_many_arguments)]
pub fn create(
    conn: &Connection,
    book_id: i64,
    page: i64,
    kind: ImageAnnotationKind,
    x: f64,
    y: f64,
    w: Option<f64>,
    h: Option<f64>,
    rotation: f64,
    payload: String,
    style: String,
) -> AppResult<i64> {
    conn.execute(
        "INSERT INTO image_annotations \
             (book_id, page, kind, x, y, w, h, rotation, payload, style) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        params![book_id, page, kind.as_str(), x, y, w, h, rotation, payload, style],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Update an image-layer mark in full (position / payload / style -- marks
/// are selectable, movable and editable, FEATURES 5.1-5.5). Affects exactly
/// one row; returns an error if the id does not exist.
#[allow(clippy::too_many_arguments)]
pub fn update(
    conn: &Connection,
    id: i64,
    x: f64,
    y: f64,
    w: Option<f64>,
    h: Option<f64>,
    rotation: f64,
    payload: String,
    style: String,
) -> AppResult<()> {
    let changed = conn.execute(
        "UPDATE image_annotations SET x = ?1, y = ?2, w = ?3, h = ?4, \
             rotation = ?5, payload = ?6, style = ?7 WHERE id = ?8",
        params![x, y, w, h, rotation, payload, style, id],
    )?;
    if changed == 0 {
        return Err(AppError::NotFound(format!("image annotation {id}")));
    }
    Ok(())
}

/// Delete an image-layer mark by id.
pub fn delete(conn: &Connection, id: i64) -> AppResult<()> {
    let changed = conn.execute(
        "DELETE FROM image_annotations WHERE id = ?1",
        params![id],
    )?;
    if changed == 0 {
        return Err(AppError::NotFound(format!("image annotation {id}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};
    use rusqlite::Connection;

    /// In-memory DB with the real schema (no migration chain needed), plus
    /// two books so `image_annotations.book_id` satisfies its foreign key.
    fn test_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        for pragma in PRAGMAS {
            conn.execute_batch(pragma).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "INSERT INTO books (id, title, original_path, stored_path, file_type) \
             VALUES (1, 'b1', '/p1', '/s1', 'pdf'), \
                    (2, 'b2', '/p2', '/s2', 'pdf');",
        )
        .unwrap();
        conn
    }

    fn create_brush(conn: &Connection, book_id: i64, page: i64) -> i64 {
        create(
            conn,
            book_id,
            page,
            ImageAnnotationKind::Brush,
            0.5,
            0.5,
            Some(0.3),
            Some(0.2),
            0.0,
            r##"{"points":[[0.1,0.1],[0.2,0.15],[0.3,0.2]]}"##.into(),
            r##"{"color":"#ff0000","strokeWidth":3}"##.into(),
        )
        .unwrap()
    }

    #[test]
    fn create_list_roundtrip() {
        let conn = test_conn();
        let id = create_brush(&conn, 1, 2);
        assert!(id > 0);

        let id2 = create(
            &conn,
            1,
            2,
            ImageAnnotationKind::Sticky,
            0.3,
            0.4,
            Some(0.2),
            Some(0.1),
            0.0,
            r##"{"text":"my note"}"##.into(),
            r##"{"fontSize":14}"##.into(),
        )
        .unwrap();
        assert!(id2 > id);

        // Other book must be isolated.
        create_brush(&conn, 2, 0);

        let anns = list(&conn, 1).unwrap();
        assert_eq!(anns.len(), 2);
        assert_eq!(anns[0].id, id);
        assert_eq!(anns[0].kind, ImageAnnotationKind::Brush);
        assert_eq!(anns[0].x, 0.5);
        assert_eq!(anns[0].payload, r##"{"points":[[0.1,0.1],[0.2,0.15],[0.3,0.2]]}"##);
        assert_eq!(anns[1].kind, ImageAnnotationKind::Sticky);
        assert_eq!(anns[1].style, r##"{"fontSize":14}"##);

        assert_eq!(list(&conn, 2).unwrap().len(), 1);
        assert!(list(&conn, 99).unwrap().is_empty());
    }

    #[test]
    fn update_and_delete() {
        let conn = test_conn();
        let id = create_brush(&conn, 1, 0);

        update(
            &conn,
            id,
            0.9,
            0.8,
            None,
            None,
            1.5,
            r##"{"points":[]}"##.into(),
            r##"{"color":"#00ff00","strokeWidth":5}"##.into(),
        )
        .unwrap();
        let anns = list(&conn, 1).unwrap();
        assert_eq!(anns[0].x, 0.9);
        assert_eq!(anns[0].w, None);
        assert_eq!(anns[0].rotation, 1.5);
        assert_eq!(anns[0].style, r##"{"color":"#00ff00","strokeWidth":5}"##);

        // Updating / deleting a missing id errors.
        assert!(update(
            &conn,
            9999,
            0.0,
            0.0,
            None,
            None,
            0.0,
            "{}".into(),
            "{}".into(),
        )
        .is_err());
        assert!(delete(&conn, 9999).is_err());

        delete(&conn, id).unwrap();
        assert!(list(&conn, 1).unwrap().is_empty());
    }
}
