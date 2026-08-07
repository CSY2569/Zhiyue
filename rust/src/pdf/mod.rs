//! PDF subsystem (FEATURES §3, TECH_ROADMAP §3.1/3.2).
//!
//! Renders pages to RGBA bitmaps, extracts text + per-character boxes for
//! precise selection, provides outline/thumbnails, and detects scanned pages.
//! Backed by `pdfium-render` (M2).
//!
//! All heavy work happens here on the Rust side; Flutter only paints the
//! returned bitmaps and hit-tests against the returned char boxes.
//!
//! The shared data types ([PageBitmap], [CharBox], [OutlineEntry]) are always
//! available so the FRB-generated bindings compile regardless of the `pdf`
//! feature. The actual pdfium-backed implementation is gated behind
//! `#[cfg(feature = "pdf")]`; without it, all functions return an error.

pub mod types;

#[cfg(feature = "pdf")]
mod pdfium;

pub use types::{CharBox, OutlineEntry, PageBitmap};

#[cfg(feature = "pdf")]
pub use pdfium::{close, extract_text, open, outline, page_has_text, render_page, thumbnail};

#[cfg(not(feature = "pdf"))]
mod fallback;
#[cfg(not(feature = "pdf"))]
pub use fallback::{close, extract_text, open, outline, page_has_text, render_page, thumbnail};
