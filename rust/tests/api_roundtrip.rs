//! End-to-end smoke test for the FFI command layer.
//!
//! This lives in `tests/` (its own process) on purpose: the pdfium document
//! handle and `OPENED_IMAGE` are process-global, so in-process unit tests
//! running in parallel can switch the active document under each other.
//!
//! It covers the commands moved onto the blocking pool (`spawn_blocking`) so
//! pdfium work never occupies an async worker: `open_book`, `render_page`,
//! `render_thumbnail`, `get_outline`, `page_has_text`, `extract_text`.

use rbwa_core::api::{
    close_book, extract_text, get_outline, import_book, init_core_with_db_path, open_book,
    page_has_text, render_page, render_thumbnail,
};

/// A one-page PDF carrying a single text object, with a computed xref table.
///
/// Hand-built so the fixture needs no PDF-writing dependency: pdfium only has
/// to parse it, and the object offsets are derived while assembling the file.
fn minimal_pdf(marker: &str) -> Vec<u8> {
    let content = format!("BT /F1 24 Tf 72 760 Td ({marker}) Tj ET");
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_string(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_string(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".to_string(),
        format!("<< /Length {} >>\nstream\n{content}\nendstream", content.len()),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_string(),
    ];

    let mut out = String::from("%PDF-1.4\n");
    let mut offsets = Vec::with_capacity(objects.len());
    for (i, body) in objects.iter().enumerate() {
        offsets.push(out.len());
        out.push_str(&format!("{} 0 obj\n{body}\nendobj\n", i + 1));
    }
    let xref_at = out.len();
    out.push_str(&format!("xref\n0 {}\n", objects.len() + 1));
    out.push_str("0000000000 65535 f \n");
    for off in &offsets {
        out.push_str(&format!("{off:010} 00000 n \n"));
    }
    out.push_str(&format!(
        "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{xref_at}\n%%EOF\n",
        objects.len() + 1
    ));
    out.into_bytes()
}

/// The pdfium document handle and `OPENED_IMAGE` are process-global, and
/// tests in one binary share the process: without this lock the two tests
/// below would open/close documents under each other.
fn serial() -> &'static tokio::sync::Mutex<()> {
    static LOCK: std::sync::OnceLock<tokio::sync::Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| tokio::sync::Mutex::new(()))
}

fn temp_dir(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("rbwa_it_{tag}_{}_{nanos}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("create temp dir");
    dir
}

#[tokio::test]
async fn import_open_render_and_extract_round_trip() {
    let _serial = serial().lock().await;
    let tmp = temp_dir("roundtrip");

    let init = init_core_with_db_path(
        tmp.join("rbwa.db").to_string_lossy().into_owned(),
    );
    assert!(init.ok, "core init failed: {:?}", init.error);

    let pdf = tmp.join("fixture.pdf");
    std::fs::write(&pdf, minimal_pdf("rbwa integration roundtrip")).expect("write fixture");

    let imported = import_book(pdf.to_string_lossy().into_owned()).await;
    assert!(imported.error.is_none(), "import failed: {:?}", imported.error);
    let stored = imported.book.expect("import returns the book").stored_path;

    let opened = open_book(stored).await;
    assert!(opened.error.is_none(), "open failed: {:?}", opened.error);
    assert_eq!(opened.page_count, 1, "fixture has exactly one page");

    // Text layer -----------------------------------------------------------------
    assert!(
        page_has_text(1, 0).await,
        "the synthetic page draws text, so it must report a text layer"
    );

    let boxes = extract_text(1, 0).await;
    assert!(boxes.error.is_none(), "extract failed: {:?}", boxes.error);
    assert!(!boxes.boxes.is_empty(), "text layer should yield char boxes");
    for b in &boxes.boxes {
        // Normalised [0,1] with a top-left origin, as Flutter expects.
        assert!(
            (0.0..=1.0).contains(&b.x) && (0.0..=1.0).contains(&b.y),
            "box out of range: char={} x={} y={}",
            b.char,
            b.x,
            b.y
        );
    }

    // Rendering ------------------------------------------------------------------
    let thumb = render_thumbnail(1, 0, 64).await;
    assert!(thumb.error.is_none(), "thumbnail failed: {:?}", thumb.error);
    assert!(thumb.width > 0 && thumb.height > 0);
    assert_eq!(
        thumb.rgba.len(),
        thumb.width as usize * thumb.height as usize * 4,
        "RGBA buffer must match the reported dimensions"
    );

    let page = render_page(1, 0, 1.0, 1.0).await;
    assert!(page.error.is_none(), "render failed: {:?}", page.error);
    assert!(page.width > 0 && page.height > 0);
    assert_eq!(page.rgba.len(), page.width as usize * page.height as usize * 4);

    // Outline: a synthetic PDF has none -- empty, not an error. ----------------
    let outline = get_outline(1).await;
    assert!(outline.error.is_none(), "outline failed: {:?}", outline.error);
    assert!(outline.entries.is_empty());

    close_book().await;

    // Formatting the temp dir away keeps /tmp clean across runs.
    let _ = std::fs::remove_dir_all(&tmp);
}
/// Proves the pdfium commands do not occupy the async worker.
///
/// `#[tokio::test]` runs a current-thread runtime, so a command that blocked
/// the worker would freeze the heartbeat task below. The loop is driven by the
/// heartbeat rather than by a fixed count: while the worker is free the
/// heartbeat advances and the loop exits within milliseconds; if a command
/// blocks, the loop spins until the deadline and the tick count stays at zero.
/// That makes the test independent of how fast the machine renders.
#[tokio::test]
async fn pdfium_commands_do_not_starve_the_async_worker() {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    let _serial = serial().lock().await;
    let tmp = temp_dir("heartbeat");
    let init = init_core_with_db_path(tmp.join("rbwa.db").to_string_lossy().into_owned());
    assert!(init.ok, "core init failed: {:?}", init.error);

    let pdf = tmp.join("fixture.pdf");
    std::fs::write(&pdf, minimal_pdf("rbwa heartbeat fixture")).expect("write fixture");
    let imported = import_book(pdf.to_string_lossy().into_owned()).await;
    let stored = imported.book.expect("import returns the book").stored_path;
    let opened = open_book(stored).await;
    assert!(opened.error.is_none(), "open failed: {:?}", opened.error);

    let ticks = Arc::new(AtomicU32::new(0));
    let heartbeat_ticks = Arc::clone(&ticks);
    let heartbeat = tokio::spawn(async move {
        loop {
            heartbeat_ticks.fetch_add(1, Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });

    const WANT_TICKS: u32 = 20;
    let deadline = Duration::from_secs(3);

    // extract_text ------------------------------------------------------------
    let start = ticks.load(Ordering::Relaxed);
    let until = Instant::now() + deadline;
    let mut calls = 0u32;
    while ticks.load(Ordering::Relaxed) - start < WANT_TICKS && Instant::now() < until {
        let boxes = extract_text(1, 0).await;
        assert!(boxes.error.is_none(), "extract failed: {:?}", boxes.error);
        calls += 1;
    }
    let extract_ticks = ticks.load(Ordering::Relaxed) - start;

    // render_page -------------------------------------------------------------
    let start = ticks.load(Ordering::Relaxed);
    let until = Instant::now() + deadline;
    let mut renders = 0u32;
    while ticks.load(Ordering::Relaxed) - start < WANT_TICKS && Instant::now() < until {
        let page = render_page(1, 0, 1.0, 1.0).await;
        assert!(page.error.is_none(), "render failed: {:?}", page.error);
        renders += 1;
    }
    let render_ticks = ticks.load(Ordering::Relaxed) - start;

    heartbeat.abort();
    close_book().await;
    let _ = std::fs::remove_dir_all(&tmp);

    assert!(
        extract_ticks >= WANT_TICKS,
        "extract_text blocked the async worker: only {extract_ticks} heartbeat ticks across {calls} calls in {deadline:?}"
    );
    assert!(
        render_ticks >= WANT_TICKS,
        "render_page blocked the async worker: only {render_ticks} heartbeat ticks across {renders} calls in {deadline:?}"
    );
}
