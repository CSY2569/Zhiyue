//! Text-layer annotation models (FEATURES 9.1.3, 9.1.10).
//!
//! Highlight / underline / strikethrough / note (§4, M3), stored in the
//! `annotations` table. Uses normalized page coordinates [0,1] x [0,1]
//! (FEATURES 4.3.4). Image-layer marks (brush / shape / sticky / stamp) are
//! an M5 milestone and will get their own types then.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

// --- Text-layer annotations (table: annotations) ---------------------------

/// Text annotation kind (FEATURES 4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextAnnotationKind {
    Highlight,
    Underline,
    Strikethrough,
    Note,
}

// Serialize as the plain DB string ("highlight") so JSON exports stay
// human-readable (FEATURES 4.5.3), instead of serde's default enum tagging.
impl Serialize for TextAnnotationKind {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for TextAnnotationKind {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let s = String::deserialize(deserializer)?;
        Self::from_db_str(&s)
            .ok_or_else(|| serde::de::Error::custom(format!("unknown annotation kind: {s}")))
    }
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

    /// Parse the DB string form back into an enum (mirror of `as_str`).
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "highlight" => Some(TextAnnotationKind::Highlight),
            "underline" => Some(TextAnnotationKind::Underline),
            "strikethrough" => Some(TextAnnotationKind::Strikethrough),
            "note" => Some(TextAnnotationKind::Note),
            _ => None,
        }
    }
}

/// A normalized rectangle on a page: all values in [0.0, 1.0].
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct NormRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A text-layer annotation (highlight / underline / strikethrough / note).
/// `rects` holds one normalized rect per selected line (FEATURES 4.3.1/4.3.2);
/// `text` is the selected text the mark was created from (sidebar display +
/// Markdown export, FEATURES 4.5.1/4.5.2).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TextAnnotation {
    pub id: i64,
    pub book_id: i64,
    pub page: i64,
    pub kind: TextAnnotationKind,
    /// Selected text the annotation was created from; None for legacy rows
    /// created before the column existed.
    pub text: Option<String>,
    /// Note text; None for mark-only annotations.
    pub content: Option<String>,
    /// One rect per line of the selection.
    pub rects: Vec<NormRect>,
    pub color: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}
