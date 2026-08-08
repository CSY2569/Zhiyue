//! Per-table repositories (M1+).
//!
//! Each module owns the CRUD logic for one table family. Repositories take a
//! borrowed `&Connection` (obtained via `db::db()`) and return `AppResult<T>`;
//! they never touch the global lock themselves nor perform file IO, keeping DB
//! transactions short and the architecture loosely coupled.

pub mod ai;
pub mod annotation;
pub mod book;
pub mod category;
pub mod image_annotation;
pub mod ocr;
pub mod progress;
pub mod search;
