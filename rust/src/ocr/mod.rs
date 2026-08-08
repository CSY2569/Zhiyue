//! OCR subsystem (FEATURES §7, TECH_ROADMAP §3.4).
//!
//! Full-page OCR chain: the engine contract, the page cache and the
//! invisible-text-layer pipeline are wired; the real rapidocr-core engine
//! (`ocr` feature, `engine.rs`) loads PP-OCRv4 models from
//! `{data_dir}/models/` (installed by `scripts/download_ocr_models.sh`,
//! FEATURES 7.1.1). Without the `ocr` feature a [StubOcrEngine] returns an
//! explicit, actionable error instead of failing silently.

use serde::{Deserialize, Serialize};

use crate::error::AppResult;
#[cfg(not(feature = "ocr"))]
use crate::error::AppError;

#[cfg(feature = "ocr")]
mod engine;
#[cfg(feature = "ocr")]
pub use engine::RapidOcrEngine;

/// A page image in raw RGBA (original resolution, FEATURES 7.1.8 -- never
/// the on-screen resolution). Kept crate-agnostic so the engine can be
/// swapped without pulling image libraries into the OCR contract.
pub struct PageImage<'a> {
    pub rgba: &'a [u8],
    pub width: u32,
    pub height: u32,
}

/// One recognized line: normalized rect (top-left origin, Flutter space) +
/// text + confidence. Serialized into `page_ocr_cache.result_json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrLine {
    pub text: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub confidence: f64,
}

/// Result of a full-page scan (FEATURES 7.1.3): line boxes + the mode that
/// produced them. The Flutter side turns the lines into an invisible text
/// layer (selection / annotation / AI work on scanned pages).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrResult {
    pub lines: Vec<OcrLine>,
    pub mode: String, // "high_precision" | "fast"
}

/// The OCR engine contract: scan a page image at its original resolution
/// (FEATURES 7.1.8 -- never the on-screen resolution). [mode] selects the
/// model set (`"high_precision"` server models or `"fast"` mobile models,
/// FEATURES 7.1.9).
///
/// Implementations: [RapidOcrEngine] (the `ocr` feature, PP-OCRv4 via
/// rapidocr-core) and [StubOcrEngine] (models not installed / no `ocr`
/// feature, returns an actionable error).
pub trait OcrEngine: Send + Sync {
    /// Whether the engine can run right now (models present, 7.1.5 lazy
    /// loading: the engine must not be loaded before the first scan).
    fn is_available(&self) -> bool;

    /// Recognize text lines in a page image with the given model set.
    fn scan(&self, image: &PageImage<'_>, mode: &str) -> AppResult<OcrResult>;
}

/// Placeholder engine: the chain (cache + text layer injection) is wired,
/// but the models are not downloaded yet. Returns a clear, actionable error
/// instead of panicking (FEATURES 7.1.1: model missing -> explicit prompt).
pub struct StubOcrEngine;

impl StubOcrEngine {
    /// The message surfaced when a scan is requested before the models are
    /// installed (shared by [OcrEngine::scan] and the api layer).
    pub const MISSING_MODELS: &'static str =
        "OCR 模型未安装：请运行 scripts/download_ocr_models.sh 下载模型后重试";
}

#[cfg(not(feature = "ocr"))]
static STUB: StubOcrEngine = StubOcrEngine;

/// The active engine. With the `ocr` feature this is the real rapidocr-core
/// engine (lazily loaded on first scan, 7.1.5); otherwise the stub.
#[cfg(feature = "ocr")]
pub fn engine() -> &'static dyn OcrEngine {
    &RapidOcrEngine
}

#[cfg(not(feature = "ocr"))]
pub fn engine() -> &'static dyn OcrEngine {
    &STUB
}

#[cfg(not(feature = "ocr"))]
impl OcrEngine for StubOcrEngine {
    fn is_available(&self) -> bool {
        false
    }

    fn scan(&self, _image: &PageImage<'_>, _mode: &str) -> AppResult<OcrResult> {
        Err(AppError::Ocr(Self::MISSING_MODELS.into()))
    }
}
