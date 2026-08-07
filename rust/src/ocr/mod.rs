//! OCR subsystem (FEATURES §7, TECH_ROADMAP §3.4).
//!
//! Full-page OCR chain (M5 skeleton): the engine contract is fixed and the
//! cache + invisible-text-layer pipeline is wired; the actual rapidocr-core
//! engine lands once the models are installed (`scripts/download_ocr_models.sh`,
//! FEATURES 7.1.1). Until then a [StubOcrEngine] returns an explicit,
//! actionable error instead of failing silently.

use serde::{Deserialize, Serialize};

use crate::error::{AppError, AppResult};

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
/// (FEATURES 7.1.8 -- never the on-screen resolution).
///
/// Implementations: [StubOcrEngine] (models not installed) and, once models
/// are downloaded, a rapidocr-core engine (default PP-OCRv4 server
/// high-precision det/rec; fast mode = mobile + int8, FEATURES 7.1.9).
pub trait OcrEngine: Send + Sync {
    /// Whether the engine can run right now (models present, 7.1.5 lazy
    /// loading: the engine must not be loaded before the first scan).
    fn is_available(&self) -> bool;

    /// Recognize text lines in a page image.
    fn scan(&self, image: &PageImage<'_>) -> AppResult<OcrResult>;
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

impl OcrEngine for StubOcrEngine {
    fn is_available(&self) -> bool {
        false
    }

    fn scan(&self, _image: &PageImage<'_>) -> AppResult<OcrResult> {
        Err(AppError::Ocr(Self::MISSING_MODELS.into()))
    }
}

static STUB: StubOcrEngine = StubOcrEngine;

/// The active engine. Returns the stub until a real engine is wired in
/// (engine lazy-loads on first scan, 7.1.5).
pub fn engine() -> &'static dyn OcrEngine {
    &STUB
}
