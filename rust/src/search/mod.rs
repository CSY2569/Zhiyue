//! Full-text search subsystem (FEATURES §3.5, TECH_ROADMAP §3.7).
//!
//! Builds a per-page text index (pdfjs text for text-PDFs, OCR text for
//! scanned) and queries it via SQLite FTS5 with jieba tokenization (M6).
//! At the skeleton stage the trait is defined with a stub impl.

use crate::error::AppResult;
use crate::models::search::SearchResult;

/// Text source for a page (FEATURES 3.5.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextSource {
    /// pdfjs native text layer.
    Pdf,
    /// OCR-recognized text.
    Ocr,
}

/// The search index contract.
pub trait SearchIndex: Send + Sync {
    /// Index one page's text. Called after PDF text extraction or OCR.
    fn index_page(
        &self,
        book_id: i64,
        page: i64,
        source: TextSource,
        text: &str,
    ) -> AppResult<()>;

    /// Drop all indexed pages for a book (e.g. on re-import / delete).
    fn drop_book(&self, book_id: i64) -> AppResult<()>;

    /// Query the index; returns per-page hits with snippets (3.5.2).
    fn search(&self, query: &str) -> AppResult<SearchResult>;
}

/// Stub implementation. Real impl (`Fts5Index`) lands in M6.
pub struct StubSearchIndex;

impl SearchIndex for StubSearchIndex {
    fn index_page(
        &self,
        _book_id: i64,
        _page: i64,
        _source: TextSource,
        _text: &str,
    ) -> AppResult<()> {
        todo!("M6: FTS5 + jieba index_page")
    }
    fn drop_book(&self, _book_id: i64) -> AppResult<()> {
        todo!("M6: FTS5 drop_book")
    }
    fn search(&self, _query: &str) -> AppResult<SearchResult> {
        todo!("M6: FTS5 + jieba search")
    }
}
