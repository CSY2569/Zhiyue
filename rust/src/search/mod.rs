//! Full-text search (FEATURES 3.5, M6).
//!
//! Indexes per-page text: native text layers (text PDFs) and OCR-scanned
//! pages. Text books build their index in a background thread after import
//! (`build_book_index`); scanned pages append incrementally on scan. The
//! DB side lives in [`crate::db::repository::search`]; this module owns
//! the jieba tokenizer and the in-memory "building" state.
//!
//! The build reads pages through an independent pdfium document
//! (`pdf::extract_document_text`), so it can run while the reader has a
//! book open without touching the reader's global document.

use std::sync::{Mutex, OnceLock};

use jieba_rs::Jieba;

use crate::db;
use crate::db::repository::search as search_repo;
use crate::error::{AppError, AppResult};

/// The jieba instance (dictionary ~5MB, loaded lazily on first use).
fn jieba() -> &'static Jieba {
    static JIEBA: OnceLock<Jieba> = OnceLock::new();
    JIEBA.get_or_init(Jieba::new)
}

/// Segment [text] into space-joined tokens -- the form `page_text_fts`
/// indexes (unicode61 splits on the spaces). Empty text -> empty string.
pub fn tokenize(text: &str) -> String {
    jieba()
        .cut(text, false)
        .into_iter()
        .map(|t| t.word)
        .filter(|w| !w.trim().is_empty())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Books whose background index build is in flight (in-memory only; the
/// ready marker in settings survives restarts).
static BUILDING: Mutex<Vec<i64>> = Mutex::new(Vec::new());

/// Whether a background build for [book_id] is running.
pub fn is_building(book_id: i64) -> bool {
    BUILDING.lock().unwrap().contains(&book_id)
}

fn mark_building(book_id: i64) {
    BUILDING.lock().unwrap().push(book_id);
}

fn mark_done(book_id: i64) {
    BUILDING.lock().unwrap().retain(|&b| b != book_id);
}

/// Start a background index build for [book_id] (idempotent per process).
/// The build thread loads the PDF through an independent document, walks
/// every page's text layer into the index, and marks the book ready.
pub fn build_book_index(book_id: i64) {
    if is_building(book_id) {
        return;
    }
    mark_building(book_id);
    std::thread::spawn(move || {
        let result = build_inner(book_id);
        mark_done(book_id);
        match result {
            Ok(pages) => {
                let conn = db::db();
                let _ = search_repo::mark_ready(&conn, book_id, pages);
                tracing::info!(id = book_id, pages, "search index built");
            }
            Err(e) => {
                // Terminal failure (e.g. a corrupt PDF): record it so the
                // build is not retried on every library visit. A vanished
                // book is not a failure worth remembering.
                if !matches!(e, AppError::NotFound(_)) {
                    let conn = db::db();
                    let _ = search_repo::mark_failed(&conn, book_id);
                }
                tracing::warn!(id = book_id, error = %e, "search index build failed");
            }
        }
    });
}

fn build_inner(book_id: i64) -> AppResult<i64> {
    let book = {
        let conn = db::db();
        crate::db::repository::book::get(&conn, book_id)?
            .ok_or_else(|| AppError::NotFound("book".into()))?
    };

    // Independent document: the reader's open PDF is never touched.
    let pages_text = crate::pdf::extract_document_text(&book.stored_path)?;
    let mut pages: i64 = 0;
    for (page, text) in pages_text.iter().enumerate() {
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        let segmented = tokenize(trimmed);
        // DB lock only around the insert; the next page's extraction runs
        // without it (a long transaction would stall the reader's progress
        // saves / annotations).
        let conn = db::db();
        search_repo::index_page(&conn, book_id, page as i64, "pdf", trimmed, &segmented)?;
        pages += 1;
    }
    Ok(pages)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tokenize_segments_chinese_and_keeps_latin() {
        let t = tokenize("量子计算入门与 Rust 编程");
        assert!(t.contains("量子"), "{t}");
        assert!(t.contains("计算"), "{t}");
        assert!(t.contains("Rust"), "{t}");
        assert!(t.contains(' '), "{t}");
        assert_eq!(tokenize("   "), "");
    }

    #[test]
    fn tokenize_handles_punctuation() {
        let t = tokenize("你好，世界！");
        assert!(t.contains("你好"), "{t}");
        assert!(t.contains("世界"), "{t}");
    }
}
