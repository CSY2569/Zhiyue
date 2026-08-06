//! RBWA Rust core layer.
//!
//! Heavy-lifting backend for the Flutter UI: PDF rendering, OCR, AI, SQLite,
//! and full-text search. Exposed to Dart via `flutter_rust_bridge` v2 through
//! the [`api`] module, which is the only FFI surface.
//!
//! Architecture (TECH_ROADMAP §1):
//! ```text
//!   Flutter (Dart)  --FRB-->  api  -->  db / pdf / ocr / ai / search
//! ```
//!
//! Module layout:
//!   - `api`      : FFI command surface (the only thing Dart imports)
//!   - `models`   : shared data types crossing the boundary
//!   - `db`       : SQLite connection + schema + repositories
//!   - `pdf`      : PDF render / text / char-box service (M2)
//!   - `ocr`      : local + multimodal OCR engines (M4/M5)
//!   - `ai`       : OpenAI-compatible streaming client (M4)
//!   - `search`   : FTS5 + jieba full-text index (M6)
//!   - `error`    : unified `AppError`

pub mod ai;
pub mod api;
pub mod db;
pub mod error;
pub mod models;
pub mod ocr;
pub mod pdf;
pub mod search;

// flutter_rust_bridge generated bindings (created by `flutter_rust_bridge_codegen`).
// The `frb_generated` mod is generated into src/frb_generated.rs; declared here
// so the crate compiles once codegen has run.
mod frb_generated;
