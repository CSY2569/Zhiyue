//! Book library models (FEATURES 9.1.1, 9.1.9).
//!
//! `Book` is the library entry; `Category` is a custom classification.
//! Milestone: M1.

use serde::{Deserialize, Serialize};

/// Document type (FEATURES 1.2). Determines text-layer acquisition strategy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BookType {
    /// Text-layer PDF -- pdfjs native text, no OCR.
    Pdf,
    /// Image file (PNG/JPG/WEBP/BMP/GIF/TIFF) -- treated like a scanned page.
    Image,
}

impl BookType {
    pub fn as_str(&self) -> &'static str {
        match self {
            BookType::Pdf => "pdf",
            BookType::Image => "image",
        }
    }

    /// Parse the `file_type` column value back into the enum.
    /// Returns `None` for unknown strings (treated as a data-integrity issue).
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "pdf" => Some(BookType::Pdf),
            "image" => Some(BookType::Image),
            _ => None,
        }
    }

    /// Infer the document type from a file extension (case-insensitive).
    /// Returns `None` for unsupported extensions.
    pub fn from_extension(ext: &str) -> Option<Self> {
        match ext.to_lowercase().as_str() {
            "pdf" => Some(BookType::Pdf),
            "png" | "jpg" | "jpeg" | "webp" | "bmp" | "gif" | "tiff" | "tif" => {
                Some(BookType::Image)
            }
            _ => None,
        }
    }
}

/// A library entry. Maps to the `books` table.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Book {
    pub id: i64,
    pub title: String,
    /// Original filesystem path -- de-dup key (FEATURES 2.1).
    pub original_path: String,
    /// Path of the copy inside the app data directory.
    pub stored_path: String,
    pub file_type: BookType,
    pub page_count: i64,
    /// Thumbnail path, nullable (FEATURES 2.6).
    pub cover_path: Option<String>,
    pub favorite: bool,
    pub category_id: Option<i64>,
    /// ISO-8601, nullable until first open.
    pub last_opened_at: Option<String>,
    pub imported_at: String,
}

/// A custom book classification (FEATURES 2.8 / 9.1.9).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Category {
    pub id: i64,
    pub name: String,
    pub sort_order: i64,
    pub created_at: String,
}
