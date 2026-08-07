//! RBWA Rust core layer.
//!
//! Heavy-lifting backend for the Flutter UI: PDF rendering, AI, SQLite.
//! Exposed to Dart via `flutter_rust_bridge` v2 through the [`api`] module,
//! which is the only FFI surface.
//!
//! Architecture (TECH_ROADMAP §1):
//! ```text
//!   Flutter (Dart)  --FRB-->  api  -->  db / pdf / ai
//! ```
//!
//! Module layout:
//!   - `api`      : FFI command surface (the only thing Dart imports)
//!   - `models`   : shared data types crossing the boundary
//!   - `db`       : SQLite connection + schema + repositories
//!   - `pdf`      : PDF render / text / char-box service (M2)
//!   - `ai`       : OpenAI-compatible streaming client (M4)
//!   - `export`   : annotation Markdown / JSON export (M3)
//!   - `error`    : unified `AppError`
//!
//! Milestones M5 (OCR, image-layer marks) and M6 (FTS5 search) will add their
//! modules here.

pub mod ai;
pub mod api;
pub mod db;
pub mod error;
pub mod export;
pub mod models;
pub mod pdf;

// flutter_rust_bridge generated bindings (created by `flutter_rust_bridge_codegen`).
// The `frb_generated` mod is generated into src/frb_generated.rs; declared here
// so the crate compiles once codegen has run.
mod frb_generated;
