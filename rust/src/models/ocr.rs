//! OCR models (FEATURES 9.1.4, 9.1.5, §7).
//!
//! `OcrLine` is a single recognized text line with its page rectangle +
//! confidence. `OcrResult` is the per-page aggregate. Milestone: M5.

use serde::{Deserialize, Serialize};

/// OCR engine mode (FEATURES 7.1.9).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum OcrMode {
    /// PP-OCRv4 server det/rec, fp32 -- accuracy first (default).
    HighPrecision,
    /// PP-OCRv4 mobile + int8 -- speed/size tradeoff (FEATURES 7.1.9).
    Fast,
}

impl OcrMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            OcrMode::HighPrecision => "high_precision",
            OcrMode::Fast => "fast",
        }
    }
}

/// A single recognized text line with its bounding box.
///
/// `quad` holds the four-point polygon (FEATURES 7.1.11) for skewed text;
/// for axis-aligned lines all four points form a rectangle.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrLine {
    pub text: String,
    /// Four-point polygon, normalized page coords: [tl, tr, br, bl].
    pub quad: [(f64, f64); 4],
    /// Recognition confidence in [0.0, 1.0] (FEATURES 7.1.6).
    pub confidence: f64,
}

/// Full-page OCR result, cached by (book_id, page) (FEATURES 7.1.4).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OcrResult {
    pub book_id: i64,
    pub page: i64,
    pub mode: OcrMode,
    pub lines: Vec<OcrLine>,
    pub created_at: String,
}
