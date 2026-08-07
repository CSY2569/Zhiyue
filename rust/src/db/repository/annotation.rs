//! `annotations` table repository (FEATURES 9.1.3 / §4 text-layer marks, M3).
//!
//! Text-layer annotations: highlight / underline / strikethrough / note.
//! `rects` is stored as a JSON array of normalized rects (one per selected
//! line, FEATURES 4.3.1). Rows cascade-delete with their book (FK).

use rusqlite::{params, Connection, Row};

use crate::error::{AppError, AppResult};
use crate::models::annotation::{NormRect, TextAnnotation, TextAnnotationKind};

/// Columns selected from `annotations`, in the order `row_to_annotation`
/// expects.
const SELECT_COLS: &str = "id, book_id, page, kind, text, content, rects, \
     color, created_at, updated_at";

/// Map a `rusqlite::Row` to a `TextAnnotation`, deserializing the rects JSON.
fn row_to_annotation(row: &Row) -> rusqlite::Result<TextAnnotation> {
    let kind_str: String = row.get(3)?;
    let rects_json: String = row.get(6)?;
    Ok(TextAnnotation {
        id: row.get(0)?,
        book_id: row.get(1)?,
        page: row.get(2)?,
        kind: TextAnnotationKind::from_db_str(&kind_str)
            .unwrap_or(TextAnnotationKind::Highlight),
        text: row.get(4)?,
        content: row.get(5)?,
        rects: serde_json::from_str(&rects_json).unwrap_or_default(),
        color: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
    })
}

/// List all annotations of a book, grouped by page then creation order
/// (FEATURES 4.5.1: sidebar groups by page).
pub fn list(conn: &Connection, book_id: i64) -> AppResult<Vec<TextAnnotation>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {SELECT_COLS} FROM annotations \
         WHERE book_id = ?1 ORDER BY page, created_at, id"
    ))?;
    let rows = stmt.query_map(params![book_id], row_to_annotation)?;
    let mut anns = Vec::new();
    for row in rows {
        anns.push(row?);
    }
    Ok(anns)
}

/// Insert a new annotation; returns the new row id.
pub fn create(
    conn: &Connection,
    book_id: i64,
    page: i64,
    kind: TextAnnotationKind,
    text: Option<String>,
    content: Option<String>,
    rects: Vec<NormRect>,
    color: Option<String>,
) -> AppResult<i64> {
    let rects_json = serde_json::to_string(&rects)
        .map_err(|e| AppError::Internal(format!("serialize rects: {e}")))?;
    conn.execute(
        "INSERT INTO annotations \
             (book_id, page, kind, text, content, rects, color) \
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![book_id, page, kind.as_str(), text, content, rects_json, color],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Update a note's text (and bump `updated_at`). Affects exactly one row;
/// returns an error if the id does not exist.
pub fn update_content(conn: &Connection, id: i64, content: Option<String>) -> AppResult<()> {
    let changed = conn.execute(
        "UPDATE annotations SET content = ?1, updated_at = datetime('now') \
         WHERE id = ?2",
        params![content, id],
    )?;
    if changed == 0 {
        return Err(AppError::NotFound(format!("annotation {id}")));
    }
    Ok(())
}

/// Delete an annotation by id.
pub fn delete(conn: &Connection, id: i64) -> AppResult<()> {
    let changed = conn.execute("DELETE FROM annotations WHERE id = ?1", params![id])?;
    if changed == 0 {
        return Err(AppError::NotFound(format!("annotation {id}")));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};
    use rusqlite::Connection;

    /// In-memory DB with the real schema (no migration chain needed), plus
    /// two books so `annotations.book_id` satisfies its foreign key.
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

    fn rect(x: f64, y: f64, w: f64, h: f64) -> NormRect {
        NormRect { x, y, w, h }
    }

    #[test]
    fn create_list_roundtrip() {
        let conn = test_conn();
        let rects = vec![rect(0.1, 0.2, 0.5, 0.03), rect(0.1, 0.25, 0.7, 0.03)];

        let id = create(
            &conn, 1, 3, TextAnnotationKind::Highlight,
            Some("selected text".into()), None, rects.clone(), Some("#ff0000".into()),
        )
        .unwrap();
        assert!(id > 0);

        let id2 = create(
            &conn, 1, 3, TextAnnotationKind::Note,
            Some("note text".into()), Some("my note".into()), rects.clone(), None,
        )
        .unwrap();
        assert!(id2 > id);

        // Other book must be isolated.
        let id3 = create(
            &conn, 2, 0, TextAnnotationKind::Underline,
            None, None, vec![rect(0.0, 0.0, 0.1, 0.1)], None,
        )
        .unwrap();
        assert!(id3 > id2);

        let anns = list(&conn, 1).unwrap();
        assert_eq!(anns.len(), 2);
        // Ordered by page, then created_at/id.
        assert_eq!(anns[0].id, id);
        assert_eq!(anns[0].kind, TextAnnotationKind::Highlight);
        assert_eq!(anns[0].text.as_deref(), Some("selected text"));
        assert_eq!(anns[0].rects, rects);
        assert_eq!(anns[1].kind, TextAnnotationKind::Note);
        assert_eq!(anns[1].content.as_deref(), Some("my note"));

        assert_eq!(list(&conn, 2).unwrap().len(), 1);
        assert!(list(&conn, 99).unwrap().is_empty());
    }

    #[test]
    fn update_and_delete() {
        let conn = test_conn();
        let id = create(
            &conn, 1, 0, TextAnnotationKind::Note,
            Some("sel".into()), None, vec![rect(0.1, 0.1, 0.2, 0.05)], None,
        )
        .unwrap();

        update_content(&conn, id, Some("edited".into())).unwrap();
        let anns = list(&conn, 1).unwrap();
        assert_eq!(anns[0].content.as_deref(), Some("edited"));

        // Updating a missing id errors.
        assert!(update_content(&conn, 9999, Some("x".into())).is_err());
        assert!(delete(&conn, 9999).is_err());

        delete(&conn, id).unwrap();
        assert!(list(&conn, 1).unwrap().is_empty());
    }

    #[test]
    fn rects_roundtrip_empty() {
        let conn = test_conn();
        let id = create(
            &conn, 1, 0, TextAnnotationKind::Strikethrough,
            None, None, vec![], None,
        )
        .unwrap();
        let anns = list(&conn, 1).unwrap();
        assert_eq!(anns[0].id, id);
        assert!(anns[0].rects.is_empty());
        assert_eq!(anns[0].kind, TextAnnotationKind::Strikethrough);
        assert!(anns[0].color.is_none());
    }
}
