//! OCR subsystem (FEATURES §7, TECH_ROADMAP §3.4).
//!
//! Dual-engine: local PP-OCRv4 (`rapidocr-core`, offline, M5) for full-page
//! scanned pages, and multimodal region OCR via the AI client (M4) for math /
//! foreign-language areas. At the skeleton stage the trait is defined with a
//! stub impl; milestone M5 fills in the local engine.
//!
//! Key principles (FEATURES 7.1):
//!   - Accuracy first: default high-precision mode, original-resolution input.
//!   - Engine lazy-loaded only on first scan (7.1.5).
//!   - Inference on a background thread, cancellable (7.1.5).
//!   - Results cached by (book_id, page) (7.1.4).

use crate::error::AppResult;
use crate::models::ocr::{OcrMode, OcrResult};

/// The OCR engine contract.
pub trait OcrEngine: Send + Sync {
    /// Lazily load the model for `mode` if not already loaded (7.1.5).
    /// First call may take time; subsequent calls are no-ops.
    fn load_engine(&self, mode: OcrMode) -> AppResult<()>;

    /// Run full-page OCR at original resolution (7.1.8).
    /// `image_rgba` + dims describe the page image; `mode` selects precision.
    /// Cancellable via the engine's internal cancel token.
    fn run_page(
        &self,
        book_id: i64,
        page: i64,
        image_rgba: &[u8],
        width: u32,
        height: u32,
        mode: OcrMode,
    ) -> AppResult<OcrResult>;

    /// Cancel any in-flight OCR for this engine instance (7.1.5).
    fn cancel(&self);

    /// Whether the model files for `mode` are present locally (7.1.1).
    fn is_model_available(&self, mode: OcrMode) -> bool;
}

/// Stub implementation. Real impl (`RapidOcrEngine`) lands in M5.
pub struct StubOcrEngine;

impl OcrEngine for StubOcrEngine {
    fn load_engine(&self, _mode: OcrMode) -> AppResult<()> {
        todo!("M5: rapidocr-core load")
    }
    fn run_page(
        &self,
        _book_id: i64,
        _page: i64,
        _image_rgba: &[u8],
        _width: u32,
        _height: u32,
        _mode: OcrMode,
    ) -> AppResult<OcrResult> {
        todo!("M5: rapidocr-core inference")
    }
    fn cancel(&self) {
        todo!("M5: cancel token")
    }
    fn is_model_available(&self, _mode: OcrMode) -> bool {
        false
    }
}
