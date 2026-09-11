//! Regressions for the bilingual-reading "API never called / translation never
//! shown" failures (M7, plan §2/§9). Both were silent: no error surfaced, the
//! app just never translated.
//!
//! 1. `translation_overview` held the process-wide DB `Mutex` and then called
//!    `cache_key()`, which re-locks the SAME non-reentrant mutex -> permanent
//!    self-deadlock. The reader calls this on every book open (`resumeIfNeeded`),
//!    so the DB guard was never released and every later translation/DB call
//!    blocked forever.
//! 2. The cache row's `target_lang` column was written with the per-page
//!    EFFECTIVE language (中英互译 -> 中文/英文) while reads looked it up under
//!    the CONFIGURED key (中英互译), so a translated page was never found again.
//!
//! Both live in one test: the DB handle is a process-global `OnceLock`, so a
//! single integration binary can only initialize it once.

use std::sync::mpsc;
use std::time::Duration;

use rbwa_core::db;
use rbwa_core::models::translate::{
    PageTranslation, ParagraphKind, ParagraphStatus, TranslatedParagraph,
};
use rbwa_core::translate;

fn set(conn: &rusqlite::Connection, key: &str, value: &str) {
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now')) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![key, value],
    )
    .unwrap();
}

fn translated(page: i64, effective_lang: &str, text: &str) -> PageTranslation {
    PageTranslation {
        page,
        target_lang: effective_lang.into(),
        provider: "reuse_ai".into(),
        source_hash: translate::stamp_source_hash(&format!("h{page}")),
        paragraphs: vec![TranslatedParagraph {
            source: "src".into(),
            translated: text.into(),
            kind: ParagraphKind::Text,
            status: ParagraphStatus::Done,
            confidence: 1.0,
            formula_regions: Vec::new(),
        }],
        coverage: 1.0,
    }
}

#[test]
fn overview_no_deadlock_and_bilingual_cache_key_roundtrip() {
    let dir = std::env::temp_dir().join(format!("rbwa_ovw_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    db::init_database_at(&dir.join("rbwa.db")).unwrap();

    let (key_lang, provider) = {
        let conn = db::db();
        conn.execute(
            "INSERT INTO books (id, title, original_path, stored_path, file_type, page_count) \
             VALUES (888, 'T', '/x.pdf', '/x.pdf', 'pdf', 10)",
            [],
        )
        .unwrap();
        // A valid book is essential: a NotFound early-return would dodge the
        // re-lock in translation_overview and hide the deadlock.
        set(&conn, "ai_config", r#"{"translate_target_lang":"中英互译"}"#);
        set(&conn, "translation_config", r#"{"provider":"ReuseAi"}"#);
        translate::cache_key_with(&conn)
    };
    assert_eq!(key_lang, "中英互译");

    // --- 1. translation_overview must return (regression: it self-deadlocked) --
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(translate::translation_overview(888).map(|o| o.total_pages));
    });
    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(10)) => {}
        Ok(other) => panic!("unexpected overview result: {other:?}"),
        Err(mpsc::RecvTimeoutError::Timeout) => {
            panic!("translation_overview self-deadlocked the DB mutex")
        }
        Err(e) => panic!("recv error: {e}"),
    }
    // The guard must also be usable again afterwards.
    let (tx2, rx2) = mpsc::channel();
    std::thread::spawn(move || {
        drop(db::db());
        let _ = tx2.send(());
    });
    rx2.recv_timeout(Duration::from_secs(5))
        .expect("DB mutex stayed locked after translation_overview");

    // --- 2. 中英互译 rows must be found under the configured key -------------
    // Save a page whose EFFECTIVE language is 英文 (中英互译 on an English page).
    {
        let conn = db::db();
        rbwa_core::db::repository::translate::save_page_translation(
            &conn,
            888,
            &key_lang,
            &translated(1, "英文", "Quantum worlds are strange."),
        )
        .unwrap();
    }
    assert!(
        translate::page_has_translation(888, 1),
        "cached translation not found under the configured key"
    );
    assert_eq!(
        translate::translation_overview(888).unwrap().translated_pages,
        1
    );
    let (col_lang, payload): (String, String) = {
        let conn = db::db();
        conn.query_row(
            "SELECT target_lang, result_json FROM page_translation_cache WHERE book_id=888",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap()
    };
    assert_eq!(col_lang, "中英互译", "key column must hold the configured key");
    assert!(payload.contains("英文"), "payload must keep the effective language");

    let _ = provider;
    let _ = std::fs::remove_dir_all(&dir);
}
