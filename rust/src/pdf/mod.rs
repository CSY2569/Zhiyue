//! PDF subsystem (FEATURES §3, TECH_ROADMAP §3.1/3.2) + image-file books
//! (FEATURES 7.3, M5).
//!
//! Renders pages to RGBA bitmaps, extracts text + per-character boxes for
//! precise selection, provides outline/thumbnails, and detects scanned pages.
//! Backed by `pdfium-render` (M2); image books (PNG / JPG / WEBP) decode via
//! the `image` crate and render through the same bitmap pipeline (M5).
//!
//! All heavy work happens here on the Rust side; Flutter only paints the
//! returned bitmaps and hit-tests against the returned char boxes.
//!
//! The shared data types ([PageBitmap], [CharBox], [OutlineEntry]) are always
//! available so the FRB-generated bindings compile regardless of the `pdf`
//! feature. The actual pdfium/image-backed implementations are gated behind
//! `#[cfg(feature = "pdf")]`; without it, all functions return an error.

pub mod types;

#[cfg(feature = "pdf")]
mod pdfium;
#[cfg(feature = "pdf")]
mod image_book;

pub use types::{CharBox, OutlineEntry, PageBitmap};

#[cfg(feature = "pdf")]
pub use pdfium::{
    close, extract_document_text, extract_text, open, outline, page_has_text, render_page,
    thumbnail,
};
#[cfg(feature = "pdf")]
pub use image_book::{
    close_image, extract_image_text, open_image, page_image_has_text, render_image,
    thumbnail_image,
};

#[cfg(not(feature = "pdf"))]
mod fallback;
#[cfg(not(feature = "pdf"))]
pub use fallback::{
    close, close_image, extract_document_text, extract_image_text, extract_text, open, open_image,
    outline, page_has_text, page_image_has_text, render_image, render_page, thumbnail,
    thumbnail_image,
};
