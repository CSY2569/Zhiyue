//! App settings models (FEATURES 9.1.8, §8.2).
//!
//! Key-value store on the Rust side; the Dart side reads/writes via the
//! `settings` API. Theme persistence (8.3) lives here too. Milestone: M1.

use serde::{Deserialize, Serialize};

/// UI theme (FEATURES 8.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ThemeMode {
    Light,
    Dark,
    System,
}

impl ThemeMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            ThemeMode::Light => "light",
            ThemeMode::Dark => "dark",
            ThemeMode::System => "system",
        }
    }
}

/// Application-level settings (UI layer only; AI config is separate).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppSettings {
    pub theme: ThemeMode,
    /// OCR default mode (FEATURES 7.1.9).
    pub ocr_mode: super::ocr::OcrMode,
    /// Whether image preprocessing is on before OCR (FEATURES 7.1.10).
    pub ocr_preprocess: bool,
}
