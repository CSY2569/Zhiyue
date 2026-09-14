//! End-to-end bilingual-reading pipeline check (M7). Exercises the real
//! `run_translate_page` against an isolated DB, a synthetic PDF, and a mock
//! OpenAI-compatible server -- the integration path the widget tests mock out.

use std::path::{Path, PathBuf};

use rbwa_core::db;
use rbwa_core::pdf;
use rbwa_core::translate::pipeline::run_translate_page;

use pdfium_render::prelude::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "rbwa_pipe_e2e_{}_{}",
        std::process::id(),
        tag
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A one-page PDF with two text lines (built under the pdfium lock).
fn make_pdf(dir: &Path) -> PathBuf {
    let path = dir.join("book.pdf");
    pdf::with_pdfium_lock(|pdfium| {
        let mut doc = pdfium.create_new_pdf()?;
        {
            let font = doc.fonts_mut().helvetica();
            let mut page = doc
                .pages_mut()
                .create_page_at_end(PdfPagePaperSize::a4())?;
            let objects = page.objects_mut();
            objects.create_text_object(
                PdfPoints::new(60.0),
                PdfPoints::new(700.0),
                "The quantum world is strange.",
                font,
                PdfPoints::new(12.0),
            )?;
            objects.create_text_object(
                PdfPoints::new(60.0),
                PdfPoints::new(680.0),
                "It follows rules we cannot see.",
                font,
                PdfPoints::new(12.0),
            )?;
            // A paragraph whose extraction has "symbol gaps" (math glyphs the
            // PDF cannot map back to text leave "(, )" holes). Placed well
            // below so it forms its own paragraph.
            objects.create_text_object(
                PdfPoints::new(60.0),
                PdfPoints::new(620.0),
                "It can be understood as a pair (, ), where:",
                font,
                PdfPoints::new(12.0),
            )?;
        }
        doc.save_to_file(&path)?;
        Ok(())
    })
    .expect("build pdf");
    path
}

/// Serves one chat-completions response per connection, forever. Every
/// request body is captured so tests can assert what the LLM was asked.
async fn mock_llm(answer: &'static str) -> (String, std::sync::Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let captured = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sink = captured.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut sock, _)) = listener.accept().await else {
                return;
            };
            let req = read_request(&mut sock).await;
            if let Ok(mut log) = sink.lock() {
                log.push(req);
            }
            let body = format!(
                r#"{{"choices":[{{"message":{{"content":"{answer}"}}}}]}}"#
            );
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = sock.write_all(resp.as_bytes()).await;
        }
    });
    (format!("http://127.0.0.1:{port}/v1"), captured)
}

async fn read_request(sock: &mut tokio::net::TcpStream) -> String {
    let mut buf: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = sock.read(&mut chunk).await.unwrap_or(0);
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(sep) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..sep]).to_string();
            let len = head
                .lines()
                .find_map(|l| {
                    l.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|v| v.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            if buf.len() >= sep + 4 + len {
                break;
            }
        }
    }
    String::from_utf8_lossy(&buf).to_string()
}

fn insert_setting(key: &str, value: &str) {
    let conn = db::db();
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now')) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![key, value],
    )
    .unwrap();
}

#[tokio::test]
async fn translate_page_end_to_end_with_mock_llm() {
    if pdf::shared_handle().is_err() {
        eprintln!("skipping: libpdfium not on the search path");
        return;
    }
    let dir = scratch_dir("main");
    db::init_database_at(&dir.join("rbwa.db")).unwrap();
    let pdf_path = make_pdf(&dir);

    {
        let conn = db::db();
        conn.execute(
            "INSERT INTO books (id, title, original_path, stored_path, file_type, page_count) \
             VALUES (1, 'T', '/x.pdf', ?1, 'pdf', 1)",
            rusqlite::params![pdf_path.to_string_lossy().to_string()],
        )
        .unwrap();
    }

    let (base, requests) = mock_llm(
        r#"[{\"i\":0,\"t\":\"量子世界很奇妙。\"},{\"i\":1,\"t\":\"它可以理解为一个二元组，其中：\"}]"#,
    )
    .await;
    insert_setting(
        "ai_config",
        &format!(
            r#"{{"base_url":"{base}","api_key":"k","text_model":"m","translate_target_lang":"中文"}}"#
        ),
    );
    insert_setting("translation_config", r#"{"provider":"ReuseAi"}"#);

    // First, confirm extraction sees the page's text at all.
    let paras = rbwa_core::translate::pipeline::extract_paragraphs(1, 1).unwrap();
    eprintln!("EXTRACTED {} paragraphs: {:?}", paras.len(), paras.iter().map(|p| &p.text).collect::<Vec<_>>());
    assert!(!paras.is_empty(), "extraction found no paragraphs");

    let mut events = Vec::new();
    let result = run_translate_page(1, 1, false, |ev| events.push(ev)).await;
    match &result {
        Ok(t) => {
            eprintln!("OK paragraphs={} coverage={}", t.paragraphs.len(), t.coverage);
            for p in &t.paragraphs {
                eprintln!("  src={:?} translated={:?} status={:?}", p.source, p.translated, p.status);
            }
        }
        Err(e) => eprintln!("ERR {e}"),
    }
    let t = result.expect("translation must succeed");
    // The cached row must carry the current extractor stamp (so an algorithm
    // fix is never masked by a stale cache entry).
    assert!(
        rbwa_core::translate::extract::is_current_source_hash(&t.source_hash),
        "source_hash not stamped: {:?}",
        t.source_hash
    );

    // Regression (v7): a paragraph whose extraction lost inline math glyphs
    // ("(, )" holes from math fonts without ToUnicode) must be TRANSLATED
    // like any other text -- sent to the LLM, whitened and re-drawn. Only
    // whole-paragraph formulas keep their original pixels.
    {
        let sent = requests.lock().unwrap().join("\n");
        assert!(
            sent.contains("pair (, )"),
            "symbol-gap paragraph was not sent to the LLM: {sent}"
        );
        assert!(
            t.paragraphs
                .iter()
                .any(|p| p.translated.contains("二元组")),
            "symbol-gap paragraph was not translated: {:?}",
            t.paragraphs
                .iter()
                .map(|p| p.translated.as_str())
                .collect::<Vec<_>>()
        );
    }

    // Phase 2 -- regression for the reported "翻译功能无效" bug: overwrite the
    // cache with an OLD-extractor row (all-formula, zero translations, no
    // version stamp) and confirm the next call RE-TRANSLATES instead of
    // serving the stale row.
    {
        let stale = rbwa_core::models::translate::PageTranslation {
            page: 1,
            target_lang: "中文".into(),
            provider: "reuse_ai".into(),
            source_hash: "deadbeef".into(), // old format, no vN: prefix
            paragraphs: vec![rbwa_core::models::translate::TranslatedParagraph {
                source: "The quantum world is strange.".into(),
                translated: String::new(),
                kind: rbwa_core::models::translate::ParagraphKind::Formula,
                status: rbwa_core::models::translate::ParagraphStatus::Done,
                confidence: 1.0,
                formula_regions: Vec::new(),
                rects: Vec::new(),
            }],
            coverage: 1.0,
        };
        let conn = db::db();
        rbwa_core::db::repository::translate::save_page_translation(&conn, 1, "中文", &stale)
            .unwrap();
    }
    let refreshed = run_translate_page(1, 1, false, |_| {}).await.unwrap();
    let translated: Vec<&str> = refreshed
        .paragraphs
        .iter()
        .map(|p| p.translated.as_str())
        .collect();
    assert!(
        translated.iter().any(|s| s.contains("量子")),
        "stale cache was served instead of re-translating: {translated:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
