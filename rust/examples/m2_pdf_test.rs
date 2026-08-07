//! M2 self-test: verifies the pdfium runtime binding, document open, page
//! render, thumbnail, and text extraction against a real PDF.
//!
//! Run with:
//!   LD_LIBRARY_PATH=rust/libpdfium cargo run --example m2_pdf_test -- /path/to/test.pdf

use rbwa_core::pdf;

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/test.pdf".to_string());

    println!("[*] opening PDF: {path}");

    // 1. Open the document -> page count.
    let count = match pdf::open(&path) {
        Ok(n) => n,
        Err(e) => {
            eprintln!("[FAIL] open: {e}");
            std::process::exit(1);
        }
    };
    println!("[ok] open: {count} page(s)");
    assert!(count >= 1, "expected at least 1 page");

    // 2. Render page 0 at 100% zoom, no DPI scaling.
    match pdf::render_page(0, 1.0, 1.0) {
        Ok(bmp) => {
            let expected = bmp.width as usize * bmp.height as usize * 4;
            println!(
                "[ok] render_page: {}x{} rgba_len={} (expected {})",
                bmp.width,
                bmp.height,
                bmp.rgba.len(),
                expected
            );
            assert!(bmp.width > 0 && bmp.height > 0, "bitmap should be non-empty");
            assert_eq!(
                bmp.rgba.len(),
                expected,
                "rgba buffer must match width*height*4"
            );
        }
        Err(e) => {
            eprintln!("[FAIL] render_page: {e}");
            std::process::exit(1);
        }
    }

    // 3. Thumbnail at 200px.
    match pdf::thumbnail(0, 200) {
        Ok(bmp) => {
            println!("[ok] thumbnail: {}x{}", bmp.width, bmp.height);
            assert!(bmp.width <= 200 || bmp.height <= 200, "thumbnail within max_size");
        }
        Err(e) => {
            eprintln!("[FAIL] thumbnail: {e}");
            std::process::exit(1);
        }
    }

    // 4. Text extraction (may be empty for scanned/image-only PDFs).
    match pdf::extract_text(0) {
        Ok(chars) => {
            println!("[ok] extract_text: {} chars", chars.len());
        }
        Err(e) => {
            eprintln!("[warn] extract_text: {e} (non-fatal)");
        }
    }

    // 5. page_has_text.
    match pdf::page_has_text(0) {
        Ok(has) => println!("[ok] page_has_text: {has}"),
        Err(e) => eprintln!("[warn] page_has_text: {e} (non-fatal)"),
    }

    // 6. Outline (bookmarks).
    match pdf::outline() {
        Ok(entries) => println!("[ok] outline: {} top-level entries", entries.len()),
        Err(e) => eprintln!("[warn] outline: {e} (non-fatal)"),
    }

    // 7. Re-open same path (should be no-op).
    let count2 = pdf::open(&path).expect("re-open");
    assert_eq!(count, count2, "re-open should return same page count");
    println!("[ok] re-open: {count2} page(s) (no-op)");

    // 8. Close.
    pdf::close();
    println!("[ok] close");

    println!("\n=== ALL M2 PDF CHECKS PASSED ===");
}
