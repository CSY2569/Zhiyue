//! Stub PDF implementation used when the `pdf` feature is disabled.
//!
//! All operations return an error directing the user to enable the feature.
//! The shared types in [`crate::pdf::types`] still compile, keeping the
//! FRB-generated Dart bindings valid.

use crate::error::{AppError, AppResult};
use crate::pdf::types::{CharBox, OutlineEntry, PageBitmap};

const NOT_BUILT: &str = "PDF support not compiled in (enable the `pdf` cargo feature)";

pub fn open(_path: &str) -> AppResult<i64> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn render_page(_page: i64, _zoom: f32, _dpi_scale: f32) -> AppResult<PageBitmap> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn thumbnail(_page: i64, _max_size: u32) -> AppResult<PageBitmap> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn extract_text(_page: i64) -> AppResult<Vec<CharBox>> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn page_has_text(_page: i64) -> AppResult<bool> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn outline() -> AppResult<Vec<OutlineEntry>> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn close() {}

pub fn open_image(_path: &str) -> AppResult<i64> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn render_image(_page: i64, _zoom: f32, _dpi_scale: f32) -> AppResult<PageBitmap> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn thumbnail_image(_page: i64, _max_size: u32) -> AppResult<PageBitmap> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn extract_image_text(_page: i64) -> AppResult<Vec<CharBox>> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn page_image_has_text(_page: i64) -> AppResult<bool> {
    Err(AppError::Pdf(NOT_BUILT.into()))
}

pub fn close_image() {}
