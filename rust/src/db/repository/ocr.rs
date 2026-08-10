//! `page_ocr_cache` table repository (FEATURES 9.1.5 / 7.1.4).
//!
//! Full-page OCR results cached per (book_id, page, ocr_mode): repeat scans
//! and page flips return instantly. Rows cascade-delete with their book (FK).

use rusqlite::{params, Connection};

use crate::error::{AppError, AppResult};
use crate::ocr::OcrResult;

/// The cached scan result for a page, if any (FEATURES 7.1.4).
pub fn get_page_ocr(
    conn: &Connection,
    book_id: i64,
    page: i64,
    mode: &str,
) -> AppResult<Option<OcrResult>> {
    let mut stmt = conn.prepare(
        "SELECT result_json FROM page_ocr_cache \
         WHERE book_id = ?1 AND page = ?2 AND ocr_mode = ?3",
    )?;
    let mut rows = stmt.query_map(params![book_id, page, mode], |row| {
        row.get::<_, String>(0)
    })?;
    match rows.next() {
        Some(row) => {
            let json = row?;
            serde_json::from_str(&json)
                .map(Some)
                .map_err(|e| AppError::Internal(format!("parse ocr cache: {e}")))
        }
        None => Ok(None),
    }
}

/// Persist a scan result (upsert; FEATURES 7.1.4).
pub fn save_page_ocr(
    conn: &Connection,
    book_id: i64,
    page: i64,
    mode: &str,
    result: &OcrResult,
) -> AppResult<()> {
    let json = serde_json::to_string(result)
        .map_err(|e| AppError::Internal(format!("serialize ocr result: {e}")))?;
    conn.execute(
        "INSERT INTO page_ocr_cache (book_id, page, ocr_mode, result_json) \
         VALUES (?1, ?2, ?3, ?4) \
         ON CONFLICT (book_id, page, ocr_mode) DO UPDATE SET \
             result_json = excluded.result_json, created_at = datetime('now')",
        params![book_id, page, mode, json],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{PRAGMAS, SCHEMA_SQL};
    use crate::ocr::OcrLine;
    use rusqlite::Connection;

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

    fn result(mode: &str) -> OcrResult {
        OcrResult {
            lines: vec![OcrLine {
                text: "你好世界".into(),
                x: 0.1,
                y: 0.2,
                w: 0.5,
                h: 0.03,
                confidence: 0.98,
            }],
            mode: mode.into(),
        }
    }

    #[test]
    fn save_get_roundtrip_and_mode_isolation() {
        let conn = test_conn();
        assert!(get_page_ocr(&conn, 1, 0, "high_precision").unwrap().is_none());

        save_page_ocr(&conn, 1, 0, "high_precision", &result("high_precision")).unwrap();
        let cached = get_page_ocr(&conn, 1, 0, "high_precision").unwrap().unwrap();
        assert_eq!(cached.lines.len(), 1);
        assert_eq!(cached.lines[0].text, "你好世界");
        assert_eq!(cached.lines[0].confidence, 0.98);

        // Different mode / page / book are isolated.
        assert!(get_page_ocr(&conn, 1, 0, "fast").unwrap().is_none());
        assert!(get_page_ocr(&conn, 1, 1, "high_precision").unwrap().is_none());
        assert!(get_page_ocr(&conn, 2, 0, "high_precision").unwrap().is_none());

        // Upsert replaces the previous result.
        save_page_ocr(&conn, 1, 0, "high_precision", &result("high_precision")).unwrap();
        assert_eq!(
            get_page_ocr(&conn, 1, 0, "high_precision").unwrap().unwrap().lines.len(),
            1
        );
    }

    #[test]
    fn manual_correction_overwrites_line_text() {
        // FEATURES 7.1.7: an edited line's text is persisted over the scan
        // result (the api::update_page_ocr_lines flow reads -> modifies ->
        // saves; this tests the save side accepts the corrected text).
        let conn = test_conn();
        save_page_ocr(&conn, 1, 0, "high_precision", &result("high_precision")).unwrap();

        let mut corrected = result("high_precision");
        corrected.lines[0].text = "你好，修正后的世界".into();
        save_page_ocr(&conn, 1, 0, "high_precision", &corrected).unwrap();

        let cached = get_page_ocr(&conn, 1, 0, "high_precision").unwrap().unwrap();
        assert_eq!(cached.lines[0].text, "你好，修正后的世界");
        // Confidence and geometry survive the edit (only text changes).
        assert_eq!(cached.lines[0].confidence, 0.98);
        assert_eq!(cached.lines[0].x, 0.1);
    }
}
