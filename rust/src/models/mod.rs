//! Shared data models crossing the Rust <-> Dart FFI boundary.
//!
//! Every type here is `frb`-exportable (plain struct / enum). Subsystems
//! produce/consume these; the Dart side receives immutable copies.
//!
//! Milestone mapping:
//!   book / category / progress -> M1
//!   annotation (text)          -> M3
//!   ai                          -> M4
//!   (ocr / search / image-layer models land with milestones M5 / M6)

pub mod ai;
pub mod annotation;
pub mod book;
pub mod progress;
