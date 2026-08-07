//! Unified error type for the RBWA Rust core.
//!
//! All subsystems (pdf / ai / ocr / db) convert their errors into
//! [`AppError`], which is exported to Flutter via `flutter_rust_bridge`.
//! This keeps the FFI boundary error surface flat and decoupled from any
//! single crate's error enum.

use thiserror::Error;

/// The single error type crossing the Rust -> Dart FFI boundary.
///
/// Variants are intentionally coarse-grained: the Dart side only needs to
/// know *which subsystem* failed and a human-readable message, not the full
/// causal chain (which is logged on the Rust side via `tracing`).
#[derive(Debug, Error)]
pub enum AppError {
    #[error("database error: {0}")]
    Database(String),

    #[error("pdf error: {0}")]
    Pdf(String),

    #[error("ai error: {0}")]
    Ai(String),

    #[error("ocr error: {0}")]
    Ocr(String),

    #[error("io error: {0}")]
    Io(String),

    #[error("not found: {0}")]
    NotFound(String),

    #[error("internal error: {0}")]
    Internal(String),
}

/// Convenience alias so subsystem code can write `Result<T>` everywhere.
pub type AppResult<T> = std::result::Result<T, AppError>;

// ---------------------------------------------------------------------------
// Conversions from common error sources.
// Subsystems attach their crate-specific errors to the most fitting variant.
// ---------------------------------------------------------------------------

impl From<std::io::Error> for AppError {
    fn from(e: std::io::Error) -> Self {
        AppError::Io(e.to_string())
    }
}

impl From<rusqlite::Error> for AppError {
    fn from(e: rusqlite::Error) -> Self {
        AppError::Database(e.to_string())
    }
}

impl From<serde_json::Error> for AppError {
    fn from(e: serde_json::Error) -> Self {
        AppError::Internal(format!("serde: {e}"))
    }
}

// pdfium-render's error type, gated behind the `pdf` feature so the crate
// compiles without pdfium-render in its dependency graph.
#[cfg(feature = "pdf")]
impl From<pdfium_render::prelude::PdfiumError> for AppError {
    fn from(e: pdfium_render::prelude::PdfiumError) -> Self {
        AppError::Pdf(e.to_string())
    }
}

// AI crate errors, gated behind the `ai` feature (M4).
#[cfg(feature = "ai")]
impl From<reqwest::Error> for AppError {
    fn from(e: reqwest::Error) -> Self {
        AppError::Ai(e.to_string())
    }
}
