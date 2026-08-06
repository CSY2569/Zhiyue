//! PDF subsystem (FEATURES §3, TECH_ROADMAP §3.1/3.2).
//!
//! Renders pages to RGBA bitmaps, extracts text + per-character boxes for
//! precise selection, provides outline/thumbnails, and detects scanned pages.
//! Backed by `pdfium-render` (M2). At the skeleton stage the trait is defined
//! with a stub impl returning `todo!()` -- milestone M2 fills it in.
//!
//! All heavy work happens here on the Rust side; Flutter only paints the
//! returned bitmaps and hit-tests against the returned char boxes.

use crate::error::AppResult;

/// A rendered page as raw RGBA pixels + dimensions.
///
/// Transferred to Flutter as `Uint8List` and uploaded to a GPU texture via
/// `ui.decodeImageFromPixels` (TECH_ROADMAP §3.1).
pub struct PageBitmap {
    pub width: u32,
    pub height: u32,
    /// RGBA, row-major, length = width * height * 4.
    pub rgba: Vec<u8>,
}

/// A single character with its page-space bounding box (pdfium coords).
///
/// Foundation for precise character-level selection (FEATURES 4.1.1) and
/// text-layer marks (4.3). Normalized coordinates are derived on the Dart side
/// from page dimensions.
pub struct CharBox {
    pub char: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

/// A bookmark / outline entry (FEATURES 3.4.2).
pub struct OutlineEntry {
    pub title: String,
    pub page: i64,
    pub children: Vec<OutlineEntry>,
}

/// The PDF service contract. The Dart side calls these through `api.rs`.
///
/// Implementations must be cancellable / non-blocking: long renders run on a
/// background thread and report progress via the FRB stream API.
pub trait PdfService: Send + Sync {
    /// Open a document at `path`. Returns page count.
    fn open(&self, path: &str) -> AppResult<i64>;

    /// Render `page` (0-indexed) at `zoom` to an RGBA bitmap.
    /// Uses original resolution when zoom implies it (OCR feeding, §7.1.8).
    fn render_page(&self, page: i64, zoom: f32) -> AppResult<PageBitmap>;

    /// Extract text + per-character boxes for a page (FEATURES 4.1.2).
    fn extract_text(&self, page: i64) -> AppResult<Vec<CharBox>>;

    /// Document outline / table of contents (FEATURES 3.4.2).
    fn outline(&self) -> AppResult<Vec<OutlineEntry>>;

    /// Whether a page has a text layer. Empty -> scanned page (FEATURES 7.1.2).
    fn page_has_text(&self, page: i64) -> AppResult<bool>;

    /// Generate a thumbnail for the sidebar (FEATURES 3.4.1).
    fn thumbnail(&self, page: i64, max_size: u32) -> AppResult<PageBitmap>;
}

/// Stub implementation. Real impl (`PdfiumService`) lands in M2.
pub struct StubPdfService;

impl PdfService for StubPdfService {
    fn open(&self, _path: &str) -> AppResult<i64> {
        todo!("M2: pdfium-render open")
    }
    fn render_page(&self, _page: i64, _zoom: f32) -> AppResult<PageBitmap> {
        todo!("M2: pdfium-render render_page")
    }
    fn extract_text(&self, _page: i64) -> AppResult<Vec<CharBox>> {
        todo!("M2: pdfium char boxes")
    }
    fn outline(&self) -> AppResult<Vec<OutlineEntry>> {
        todo!("M2: pdfium outline")
    }
    fn page_has_text(&self, _page: i64) -> AppResult<bool> {
        todo!("M2: pdfium text detection")
    }
    fn thumbnail(&self, _page: i64, _max_size: u32) -> AppResult<PageBitmap> {
        todo!("M2: pdfium thumbnail")
    }
}
