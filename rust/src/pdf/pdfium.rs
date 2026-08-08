//! pdfium-backed PDF implementation (M2).
//!
//! Binds the native `libpdfium.so` (bundled in the app's `lib/` dir) via
//! `pdfium-render`, caches the `Pdfium` handle in a process-global `OnceLock`,
//! and holds the currently-open document behind a `Mutex`. Only one document
//! is open at a time (the reader is single-document).

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use pdfium_render::prelude::*;

use crate::error::{AppError, AppResult};
use crate::pdf::types::{CharBox, OutlineEntry, PageBitmap};

/// Cached singleton `Pdfium` handle (bound once per process).
static PDFIUM: OnceLock<Pdfium> = OnceLock::new();

/// The currently-open document. Only one PDF is open at a time.
static DOC: Mutex<Option<PdfDocument<'static>>> = Mutex::new(None);

/// The stored path of the currently-open document, for re-open detection.
static DOC_PATH: Mutex<Option<String>> = Mutex::new(None);

// The `PdfDocument` borrows from the `Pdfium` in `PDFIUM`, which lives for the
// process lifetime (OnceLock). The `thread_safe` feature makes the handles
// `Send + Sync`. We transmute the borrow to `'static` so it can be stored in
// the static `DOC`; this is sound because `PDFIUM` is never replaced/dropped.

/// Returns the cached `Pdfium` handle, binding the native library on first call.
fn pdfium() -> AppResult<&'static Pdfium> {
    if let Some(h) = PDFIUM.get() {
        return Ok(h);
    }
    // Candidate locations for libpdfium.so, tried in order:
    //   1. the executable's directory            (dev: .so next to the binary)
    //   2. the executable's `lib/` subdirectory  (bundled app: bundle/lib/)
    //   3. a system-installed library            (e.g. distro package)
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(dir) = exe_dir() {
        candidates.push(dir.clone());
        candidates.push(dir.join("lib"));
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd);
    }

    let mut bindings = None;
    for dir in &candidates {
        if let Ok(b) = Pdfium::bind_to_library(Pdfium::pdfium_platform_library_name_at_path(dir))
        {
            bindings = Some(b);
            break;
        }
    }
    let bindings = bindings
        .or_else(|| Pdfium::bind_to_system_library().ok())
        .ok_or_else(|| {
            AppError::Pdf(
                "libpdfium not found: run scripts/fetch_pdfium.sh and rebuild".into(),
            )
        })?;
    let handle = Pdfium::new(bindings);
    let _ = PDFIUM.set(handle);
    Ok(PDFIUM.get().expect("pdfium just set"))
}

/// Resolves the directory containing the running executable (bundle `lib/`).
fn exe_dir() -> Option<PathBuf> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(std::path::Path::to_path_buf))
}

/// Opens a PDF document and caches it as the active document.
/// Returns the page count. Re-opening the same path is a no-op.
pub fn open(path: &str) -> AppResult<i64> {
    let pdfium = pdfium()?;

    // Skip re-opening if the same document is already active.
    let already = DOC_PATH.lock().unwrap().clone();
    if already.as_deref() == Some(path) {
        if let Some(doc) = DOC.lock().unwrap().as_ref() {
            return Ok(doc.pages().len() as i64);
        }
    }

    let doc = pdfium.load_pdf_from_file(path, None)?;
    let count = doc.pages().len() as i64;

    // SAFETY: the borrow from `pdfium` is 'static because `PDFIUM` never drops.
    let doc_static: PdfDocument<'static> = unsafe { std::mem::transmute(doc) };
    *DOC.lock().unwrap() = Some(doc_static);
    *DOC_PATH.lock().unwrap() = Some(path.to_string());

    Ok(count)
}

/// Ensures a document is open, running `f` against it.
fn with_doc<F, R>(f: F) -> AppResult<R>
where
    F: FnOnce(&PdfDocument<'_>) -> AppResult<R>,
{
    let guard = DOC.lock().unwrap();
    let doc = guard
        .as_ref()
        .ok_or_else(|| AppError::Pdf("no document open -- call open_book first".into()))?;
    f(doc)
}

/// Renders `page` (0-indexed) at the given zoom factor (1.0 = 100%) to RGBA.
/// `dpi_scale` multiplies the pixel dimensions for high-DPI output.
pub fn render_page(page: i64, zoom: f32, dpi_scale: f32) -> AppResult<PageBitmap> {
    with_doc(|doc| {
        let pg = doc.pages().get(page as PdfPageIndex)?;

        let page_w = pg.width().value;
        let page_h = pg.height().value;
        let scale = zoom * dpi_scale;
        let target_w = (page_w * scale).max(1.0) as i32;
        let target_h = (page_h * scale).max(1.0) as i32;

        // `as_rgba_bytes()` normalizes the pixel format to RGBA regardless of
        // the bitmap's internal format, so we use the default (BGRA).
        let config = PdfRenderConfig::new()
            .set_target_width(target_w)
            .set_target_height(target_h);

        let bitmap = pg.render_with_config(&config)?;

        Ok(PageBitmap {
            width: bitmap.width() as u32,
            height: bitmap.height() as u32,
            rgba: bitmap.as_rgba_bytes(),
        })
    })
}

/// Generates a small thumbnail for the sidebar (FEATURES 3.4.1).
/// `max_size` is the longest edge in pixels.
pub fn thumbnail(page: i64, max_size: u32) -> AppResult<PageBitmap> {
    with_doc(|doc| {
        let pg = doc.pages().get(page as PdfPageIndex)?;

        let config = PdfRenderConfig::new().thumbnail(max_size as i32);

        let bitmap = pg.render_with_config(&config)?;

        Ok(PageBitmap {
            width: bitmap.width() as u32,
            height: bitmap.height() as u32,
            rgba: bitmap.as_rgba_bytes(),
        })
    })
}

/// Extracts text + per-character bounding boxes for a page (FEATURES 4.1.2).
/// Coordinates are normalized to [0,1] relative to page dimensions. M2
/// provides the data; M3 consumes it for selection.
pub fn extract_text(page: i64) -> AppResult<Vec<CharBox>> {
    with_doc(|doc| {
        let pg = doc.pages().get(page as PdfPageIndex)?;

        let page_w = pg.width().value.max(1.0);
        let page_h = pg.height().value.max(1.0);
        let text = pg.text()?;
        let mut out = Vec::new();
        for char in text.chars().iter() {
            let ch = char.unicode_string().unwrap_or_default();
            if ch.is_empty() {
                continue;
            }
            // tight_bounds -> PdfRect -> to_quad_points gives us left/bottom/
            // width/height accessors (PdfRect's own corners are private).
            if let Ok(rect) = char.tight_bounds() {
                let quad = rect.to_quad_points();
                let w = (quad.width().value / page_w).max(0.0);
                let h = (quad.height().value / page_h).max(0.0);
                out.push(CharBox {
                    char: ch,
                    x: (quad.left().value / page_w).max(0.0),
                    // PDF's origin is bottom-left; Flutter's is top-left, so
                    // flip y here. Selection/highlight layers then use the
                    // boxes as-is (M3, FEATURES 4.1.2 / 4.3.4).
                    y: (1.0 - (quad.bottom().value + quad.height().value) / page_h)
                        .clamp(0.0, 1.0),
                    w,
                    h,
                });
            }
        }
        Ok(out)
    })
}

/// Whether a page has extractable text (FEATURES 7.1.2: empty -> scanned).
pub fn page_has_text(page: i64) -> AppResult<bool> {
    with_doc(|doc| {
        let pg = doc.pages().get(page as PdfPageIndex)?;
        let text = pg.text()?;
        Ok(!text.is_empty() && !text.all().trim().is_empty())
    })
}

/// Document outline / table of contents (FEATURES 3.4.2).
/// Recursively walks bookmarks; each entry carries a 0-indexed page or -1.
pub fn outline() -> AppResult<Vec<OutlineEntry>> {
    with_doc(|doc| {
        let bookmarks = doc.bookmarks();
        let mut out = Vec::new();
        for bm in bookmarks.iter() {
            out.push(bookmark_to_entry(&bm));
        }
        Ok(out)
    })
}

fn bookmark_to_entry(bm: &PdfBookmark<'_>) -> OutlineEntry {
    let title = bm.title().unwrap_or_default();
    let page = bm
        .destination()
        .and_then(|d| d.page_index().ok())
        .map(|i| i as i64)
        .unwrap_or(-1);
    let mut children = Vec::new();
    if let Some(child) = bm.first_child() {
        let mut sibling = child;
        loop {
            children.push(bookmark_to_entry(&sibling));
            match sibling.next_sibling() {
                Some(next) => sibling = next,
                None => break,
            }
        }
    }
    OutlineEntry {
        title,
        page,
        children,
    }
}

/// Closes the active document, releasing its memory.
pub fn close() {
    *DOC.lock().unwrap() = None;
    *DOC_PATH.lock().unwrap() = None;
}
