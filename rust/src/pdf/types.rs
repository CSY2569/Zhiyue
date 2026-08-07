//! Shared PDF data types exported to Flutter via FRB.
//!
//! These types are always compiled (even without the `pdf` feature) so the
//! generated Dart bindings remain valid. They carry rendered bitmaps,
//! per-character boxes, and outline entries between Rust and Flutter.

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

/// A single character with its normalized page-space bounding box.
///
/// Coordinates are normalized to [0,1] relative to page dimensions, so they
/// remain correct at any zoom. Foundation for precise character-level
/// selection (FEATURES 4.1.1) and text-layer marks (4.3).
pub struct CharBox {
    pub char: String,
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

/// A bookmark / outline entry (FEATURES 3.4.2). `page` is 0-indexed; -1 means
/// the destination is not a page (e.g. a URL action).
pub struct OutlineEntry {
    pub title: String,
    pub page: i64,
    pub children: Vec<OutlineEntry>,
}
