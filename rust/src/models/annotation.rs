//! Annotation models (FEATURES 9.1.3, 9.1.10).
//!
//! Two disjoint kinds, stored in separate tables:
//!   - Text-layer marks: highlight / underline / strikethrough / note (§4, M3)
//!   - Image-layer marks: brush / shape / sticky / stamp (§5, M5)
//!
//! Both use normalized page coordinates [0,1] x [0,1] (FEATURES 4.3.4, 5.5).

use serde::{Deserialize, Serialize};

// --- Text-layer annotations (table: annotations) ---------------------------

/// Text annotation kind (FEATURES 4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TextAnnotationKind {
    Highlight,
    Underline,
    Strikethrough,
    Note,
}

impl TextAnnotationKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            TextAnnotationKind::Highlight => "highlight",
            TextAnnotationKind::Underline => "underline",
            TextAnnotationKind::Strikethrough => "strikethrough",
            TextAnnotationKind::Note => "note",
        }
    }
}

/// A normalized rectangle on a page: all values in [0.0, 1.0].
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A text-layer annotation (highlight / underline / strikethrough / note).
/// `rects` holds one normalized rect per selected line (FEATURES 4.3.1/4.3.2).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextAnnotation {
    pub id: i64,
    pub book_id: i64,
    pub page: i64,
    pub kind: TextAnnotationKind,
    /// Note text; None for mark-only annotations.
    pub content: Option<String>,
    /// One rect per line of the selection.
    pub rects: Vec<NormRect>,
    pub color: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

// --- Image-layer annotations (table: image_annotations) ---------------------

/// Image annotation kind (FEATURES 5.1-5.4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ImageAnnotationKind {
    /// Freehand brush stroke -- vector path (FEATURES 5.1).
    Brush,
    /// Geometric shape: arrow / rect / ellipse (FEATURES 5.4).
    Shape,
    /// Floating sticky note / text box (FEATURES 5.2).
    Sticky,
    /// Stamp / signature image (FEATURES 5.3).
    Stamp,
}

impl ImageAnnotationKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ImageAnnotationKind::Brush => "brush",
            ImageAnnotationKind::Shape => "shape",
            ImageAnnotationKind::Sticky => "sticky",
            ImageAnnotationKind::Stamp => "stamp",
        }
    }
}

/// An image-layer mark. Payload + style are kind-specific JSON blobs; the
/// typed Rust structs for each will land in milestone M5.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImageAnnotation {
    pub id: i64,
    pub book_id: i64,
    pub page: i64,
    pub kind: ImageAnnotationKind,
    pub x: f64,
    pub y: f64,
    pub w: Option<f64>,
    pub h: Option<f64>,
    pub rotation: f64,
    /// JSON: kind-specific data (path points / text / image ref / geometry).
    pub payload: String,
    /// JSON: style (color / strokeWidth / fill / fontSize).
    pub style: String,
    pub created_at: String,
}
