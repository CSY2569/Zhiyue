//! Search models (FEATURES 9.1.6, §3.5).
//!
//! Full-text search results: per-page hits with context snippets. Milestone: M6.

use serde::{Deserialize, Serialize};

/// A single search hit on one page.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchHit {
    pub book_id: i64,
    pub page: i64,
    /// Short surrounding text around the match (3.5.2).
    pub snippet: String,
}

/// Aggregated search result for a query.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub query: String,
    pub hits: Vec<SearchHit>,
    pub total: i64,
}
