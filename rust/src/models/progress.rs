//! Reading progress (FEATURES 9.1.2, 3.3.4).
//!
//! Page number + zoom + view mode per book. Auto-saved (debounced) and
//! restored on reopen. Milestone: M1 (stub) / M2 (real).

use serde::{Deserialize, Serialize};

/// Reader view mode (FEATURES 3.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ViewMode {
    /// Single page, continuous scroll (3.1.1).
    Single,
    /// Two pages side by side, row height = max of the pair, vertical scroll (3.1.2).
    DoubleScroll,
    /// Two-page flip mode, no scrollbar, centered pair, step 2 (3.1.3).
    DoublePage,
}

impl ViewMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            ViewMode::Single => "single",
            ViewMode::DoubleScroll => "double_scroll",
            ViewMode::DoublePage => "double_page",
        }
    }
}

/// Persisted reading position for a book.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ReadingProgress {
    pub book_id: i64,
    pub page: i64,
    /// Zoom factor, default 1.2 = 120% (FEATURES 3.2.1).
    pub zoom: f64,
    pub view_mode: ViewMode,
    pub updated_at: String,
}
