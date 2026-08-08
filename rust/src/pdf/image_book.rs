//! Image-file books (FEATURES 7.3): decode PNG / JPG / WEBP and render them
//! through the same pipeline as PDF pages (zoom tiers, thumbnails). Image
//! books have no text layer -- OCR (M5) provides one for selection.

use std::sync::Mutex;

use image::GenericImageView;

use crate::error::{AppError, AppResult};
use crate::pdf::types::{CharBox, PageBitmap};

/// The currently open image book, decoded at its original resolution (kept
/// as the OCR input source; rendering resizes on demand).
static IMAGE_DOC: Mutex<Option<ImageDoc>> = Mutex::new(None);

struct ImageDoc {
    /// Decoded original-resolution image.
    image: image::DynamicImage,
}

/// Open an image file as a book (an image book always has exactly one page).
pub fn open_image(path: &str) -> AppResult<i64> {
    let img = image::open(path)
        .map_err(|e| AppError::Internal(format!("decode image {path}: {e}")))?;
    *IMAGE_DOC.lock().unwrap() = Some(ImageDoc { image: img });
    Ok(1)
}

/// Close the currently open image book, freeing its memory.
pub fn close_image() {
    *IMAGE_DOC.lock().unwrap() = None;
}

/// Lock the open document and run [f] with it; errors clearly when no image
/// is open (both render paths share this guard + lookup).
fn with_doc<T>(f: impl FnOnce(&ImageDoc) -> AppResult<T>) -> AppResult<T> {
    let guard = IMAGE_DOC.lock().unwrap();
    let doc = guard
        .as_ref()
        .ok_or_else(|| AppError::Internal("no image open -- call open_image first".into()))?;
    f(doc)
}

/// Render the single page at `zoom * dpi_scale` of the original size
/// (FEATURES 3.6.2: pages stay sharp when zooming).
pub fn render_image(_page: i64, zoom: f32, dpi_scale: f32) -> AppResult<PageBitmap> {
    with_doc(|doc| {
        let scale = (zoom * dpi_scale) as f64;
        let w = ((doc.image.width() as f64) * scale).round().max(1.0) as u32;
        let h = ((doc.image.height() as f64) * scale).round().max(1.0) as u32;
        let resized = doc
            .image
            .resize(w, h, image::imageops::FilterType::Lanczos3);
        Ok(PageBitmap {
            width: w,
            height: h,
            rgba: resized.to_rgba8().into_raw(),
        })
    })
}

/// Render a small thumbnail for the sidebar (FEATURES 3.4.1): the longest
/// side is capped at [max_size], keeping the aspect ratio.
pub fn thumbnail_image(_page: i64, max_size: u32) -> AppResult<PageBitmap> {
    with_doc(|doc| {
        let (w, h) = doc.image.dimensions();
        let (tw, th) = if w >= h {
            let th = ((h as f64) * (max_size as f64) / (w as f64)).round().max(1.0) as u32;
            (max_size, th)
        } else {
            let tw = ((w as f64) * (max_size as f64) / (h as f64)).round().max(1.0) as u32;
            (tw, max_size)
        };
        let resized = doc
            .image
            .resize(tw, th, image::imageops::FilterType::Lanczos3);
        Ok(PageBitmap {
            width: tw,
            height: th,
            rgba: resized.to_rgba8().into_raw(),
        })
    })
}

/// Image books have no text layer; the OCR pipeline (M5) injects one.
pub fn extract_image_text(_page: i64) -> AppResult<Vec<CharBox>> {
    Ok(Vec::new())
}

/// Without OCR, image pages have no text layer (FEATURES 7.1.2 detection).
pub fn page_image_has_text(_page: i64) -> AppResult<bool> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny 2x2 RGBA PNG written to a temp file.
    fn write_test_png(path: &str) {
        let img = image::RgbaImage::from_pixel(2, 2, image::Rgba([255, 0, 0, 255]));
        img.save(path).unwrap();
    }

    #[test]
    fn open_render_thumbnail_roundtrip() {
        let path = std::env::temp_dir().join("rbwa_image_book_test.png");
        let path_str = path.to_string_lossy().to_string();
        write_test_png(&path_str);

        assert_eq!(open_image(&path_str).unwrap(), 1);
        assert!(!page_image_has_text(0).unwrap());
        assert!(extract_image_text(0).unwrap().is_empty());

        let full = render_image(0, 1.0, 1.0).unwrap();
        assert_eq!((full.width, full.height), (2, 2));
        assert_eq!(full.rgba.len(), 2 * 2 * 4);

        // Zoom doubles the size; thumbnails cap the longest side.
        let zoomed = render_image(0, 2.0, 1.0).unwrap();
        assert_eq!((zoomed.width, zoomed.height), (4, 4));
        let thumb = thumbnail_image(0, 1).unwrap();
        assert_eq!((thumb.width, thumb.height), (1, 1));

        // Rendering before open errors clearly.
        close_image();
        assert!(render_image(0, 1.0, 1.0).is_err());

        std::fs::remove_file(&path).ok();
    }
}
