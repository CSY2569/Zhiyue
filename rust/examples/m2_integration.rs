//! M2 integration test: import a PDF (with cover + page count population),
//! then verify open_book / render_page / get_outline / progress save/restore
//! all work end-to-end against the real DB and pdfium.
//!
//! Run with:
//!   LD_LIBRARY_PATH=rust/libpdfium cargo run --example m2_integration -- /tmp/test.pdf

use rbwa_core::api;


#[tokio::main]
async fn main() {
    let pdf_path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "/tmp/test.pdf".to_string());

    let init = api::init_core();
    assert!(init.ok, "core init failed: {:?}", init.error);

    // Clean slate: delete any existing book with this path.
    // (Import dedups by original_path, so we test fresh import by deleting first.)

    // 1. Import the PDF -> should populate page_count and cover_path.
    println!("[*] importing PDF: {pdf_path}");
    let r = api::import_book(pdf_path.clone()).await;
    println!("  existed={}, error={:?}", r.already_existed, r.error);
    assert!(r.book.is_some(), "import should succeed");
    let book = r.book.as_ref().unwrap();

    // If it already existed from a prior run, page_count/cover may already be set.
    println!("[ok] imported book id={}, page_count={}, cover={:?}",
        book.id, book.page_count, book.cover_path);

    // page_count should be >= 1 for a real PDF (pdfium populates it on import).
    // If the import just returned an existing record, it still has the count.
    assert!(
        book.page_count >= 1,
        "PDF page_count should be >= 1, got {}",
        book.page_count
    );

    // cover_path should be set (pdfium rendered page 0 as a thumbnail).
    assert!(
        book.cover_path.is_some(),
        "PDF cover_path should be set after import"
    );
    let cover = book.cover_path.as_ref().unwrap();
    assert!(
        std::path::Path::new(cover).exists(),
        "cover file should exist: {cover}"
    );
    println!("[ok] cover file exists: {cover}");

    // 2. Open the book via the reader API.
    let open_result = api::open_book(book.stored_path.clone()).await;
    println!("[ok] open_book: page_count={}, has_outline={}, error={:?}",
        open_result.page_count, open_result.has_outline, open_result.error);
    assert!(open_result.error.is_none(), "open_book should succeed");
    assert_eq!(open_result.page_count, book.page_count);

    // 3. Render page 0.
    let render = api::render_page(book.id, 0, 1.0, 1.0).await;
    println!("[ok] render_page: {}x{}, rgba_len={}, error={:?}",
        render.width, render.height, render.rgba.len(), render.error);
    assert!(render.error.is_none(), "render should succeed");
    assert!(render.width > 0 && render.height > 0);
    assert_eq!(
        render.rgba.len(),
        render.width as usize * render.height as usize * 4
    );

    // 4. Render thumbnail.
    let thumb = api::render_thumbnail(book.id, 0, 200).await;
    println!("[ok] render_thumbnail: {}x{}, error={:?}",
        thumb.width, thumb.height, thumb.error);
    assert!(thumb.error.is_none());

    // 5. Get outline.
    let outline = api::get_outline(book.id).await;
    println!("[ok] get_outline: {} entries, error={:?}",
        outline.entries.len(), outline.error);
    assert!(outline.error.is_none());

    // 6. page_has_text.
    let has_text = api::page_has_text(book.id, 0).await;
    println!("[ok] page_has_text: {has_text}");

    // 7. Save progress.
    let saved = api::save_progress(book.id, 1, 1.5, "single".into());
    println!("[ok] save_progress: {saved}");
    assert_eq!(saved, 1);

    // 8. Load progress.
    let progress = api::get_progress(book.id);
    println!("[ok] get_progress: {:?}", progress.as_ref().map(|p| (p.page, p.zoom)));
    assert!(progress.is_some());
    let p = progress.unwrap();
    assert_eq!(p.page, 1);
    assert!((p.zoom - 1.5).abs() < 0.01);

    // 9. Close the book.
    api::close_book().await;
    println!("[ok] close_book");

    // 10. Clean up: delete the book (cascades + removes stored file + cover).
    let deleted = api::delete_book(book.id);
    println!("[ok] delete_book: {deleted}");
    assert_eq!(deleted, 1);
    assert!(!std::path::Path::new(&book.stored_path).exists());
    assert!(!std::path::Path::new(cover).exists(), "cover file should be removed");

    // 11. Re-import dedup test (already deleted, so fresh import).
    let r2 = api::import_book(pdf_path.clone()).await;
    assert!(!r2.already_existed, "re-import after delete should be fresh");
    let book2 = r2.book.as_ref().unwrap();
    println!("[ok] re-import fresh: id={}, page_count={}", book2.id, book2.page_count);

    // 12. Dedup: re-import same path -> already_existed.
    let r3 = api::import_book(pdf_path.clone()).await;
    println!("[ok] dedup: already_existed={}", r3.already_existed);
    assert!(r3.already_existed);
    assert_eq!(r3.book.as_ref().unwrap().id, book2.id);

    // Clean up.
    let _ = api::delete_book(book2.id);
    

    println!("\n=== ALL M2 INTEGRATION CHECKS PASSED ===");
}
