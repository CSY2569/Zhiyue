//! Shared data models crossing the Rust <-> Dart FFI boundary.
//!
//! Every type here is `frb`-exportable (plain struct / enum). Subsystems
//! produce/consume these; the Dart side receives immutable copies. Complex
//! models get a matching `freezed` class on the Dart side for ergonomics.
//!
//! Milestone mapping:
//!   book / category / progress -> M1
//!   annotation (text + image)  -> M3 / M5
//!   ocr                         -> M5
//!   ai                          -> M4
//!   search                      -> M6
//!   settings                    -> M1

pub mod ai;
pub mod annotation;
pub mod book;
pub mod ocr;
pub mod progress;
pub mod search;
pub mod settings;
