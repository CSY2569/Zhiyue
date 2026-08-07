use rbwa_core::api;
use std::io::Write;

#[tokio::main]
async fn main() {
    let init = api::init_core();
    assert!(init.ok, "core init failed: {:?}", init.error);
    println!("[ok] core init, schema={}", init.schema_version);

    // Start empty.
    let books = api::list_books();
    println!("[ok] initial book count: {}", books.len());

    // Create a temp test image and import it.
    let tmp = std::env::temp_dir().join("rbwa_m1_test.png");
    let mut f = std::fs::File::create(&tmp).unwrap();
    // Minimal 1x1 PNG.
    let png: &[u8] = &[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
        0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
        0x42, 0x60, 0x82,
    ];
    f.write_all(png).unwrap();
    drop(f);

    let path_str = tmp.to_string_lossy().to_string();
    let r1 = api::import_book(path_str.clone()).await;
    println!("[ok] import #1: existed={}, error={:?}", r1.already_existed, r1.error);
    assert!(r1.book.is_some(), "import should succeed");
    assert!(!r1.already_existed, "first import should be new");
    let book = r1.book.as_ref().unwrap();
    assert_eq!(book.file_type, rbwa_core::models::book::BookType::Image);
    assert_eq!(book.page_count, 1);
    assert!(book.cover_path.is_some(), "image cover should be set");
    let book_id = book.id;

    // De-dup: re-import the same path.
    let r2 = api::import_book(path_str.clone()).await;
    println!("[ok] import #2 (dedup): existed={}, error={:?}", r2.already_existed, r2.error);
    assert!(r2.already_existed, "second import should be deduped");
    assert_eq!(r2.book.as_ref().unwrap().id, book_id);

    // List reflects one book.
    let books = api::list_books();
    println!("[ok] book count after import: {}", books.len());
    assert_eq!(books.len(), 1);

    // Toggle favorite.
    let toggled = api::toggle_favorite(book_id);
    println!("[ok] toggle favorite: {:?}", toggled.as_ref().map(|b| b.favorite));
    assert!(toggled.is_some());
    assert!(toggled.unwrap().favorite);

    // Categories: create, list, assign.
    let cat = api::create_category("测试分类".into());
    println!("[ok] create category: {:?}", cat.as_ref().map(|c| &c.name));
    assert!(cat.is_some());
    let cat_id = cat.unwrap().id;
    let cats = api::list_categories();
    println!("[ok] category count: {}", cats.len());
    assert_eq!(cats.len(), 1);

    let assign = api::assign_category(book_id, Some(cat_id));
    println!("[ok] assign category: {}", assign);
    assert_eq!(assign, 1);
    let b_after = api::list_books().pop().unwrap();
    assert_eq!(b_after.category_id, Some(cat_id));

    // Touch last opened.
    let touched = api::touch_last_opened(book_id);
    println!("[ok] touch last opened: {}", touched);
    assert_eq!(touched, 1);

    // Rename category.
    let renamed = api::rename_category(cat_id, "重命名分类".into());
    println!("[ok] rename category: {}", renamed);
    assert_eq!(renamed, 1);

    // Delete category -> books fall back to unclassified.
    let deleted_cat = api::delete_category(cat_id);
    println!("[ok] delete category: {}", deleted_cat);
    assert_eq!(deleted_cat, 1);
    let b_after_cat_del = api::list_books().pop().unwrap();
    assert_eq!(b_after_cat_del.category_id, None, "book should be unclassified after category delete");
    assert_eq!(api::list_categories().len(), 0);

    // Verify the stored file exists.
    let stored = &b_after_cat_del.stored_path;
    assert!(std::path::Path::new(stored).exists(), "stored file should exist: {}", stored);
    println!("[ok] stored file exists: {}", stored);

    // Delete book -> file removed, list empty.
    let del = api::delete_book(book_id);
    println!("[ok] delete book: {}", del);
    assert_eq!(del, 1);
    assert!(!std::path::Path::new(stored).exists(), "stored file should be removed");
    assert_eq!(api::list_books().len(), 0);

    // Unsupported extension.
    let bad = std::env::temp_dir().join("rbwa_m1_test.xyz");
    std::fs::write(&bad, b"data").unwrap();
    let r_bad = api::import_book(bad.to_string_lossy().to_string()).await;
    println!("[ok] import unsupported: error={:?}", r_bad.error);
    assert!(r_bad.error.is_some());
    assert!(r_bad.book.is_none());

    // Cleanup.
    let _ = std::fs::remove_file(&tmp);
    let _ = std::fs::remove_file(&bad);

    println!("\n=== ALL M1 CHECKS PASSED ===");
}
