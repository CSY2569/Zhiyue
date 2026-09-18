//! Book-translation job (BabelDOC sidecar).
//!
//! One whole-book run: spawn the engine (`python -c ... main()` -- see
//! `engine::babeldoc_argv`), stream its output lines as progress events,
//! support cancellation, then record the produced mono/dual PDFs in a
//! manifest under `translated/{book_id}/`. There is no per-page pipeline any
//! more: the pane renders pages of the produced mono PDF.
//!
//! v1 scope: whole-book runs against an OpenAI-compatible endpoint (the AI
//! settings' config, reused). Chunked/随进度 runs and DeepL arrive later.

use std::io::Read;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::error::{AppError, AppResult};
use crate::models::translate::{BookTranslateEvent, BookTranslation};

/// A run is in flight (single job at a time; the UI disables the button).
static RUNNING: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);

/// Whether a book-translation job is running.
pub fn is_running() -> bool {
    RUNNING.load(Ordering::SeqCst)
}

/// Requests cancellation of the running job (kills the engine process).
pub fn cancel() {
    CANCEL.store(true, Ordering::SeqCst);
}

fn artifact_dir(book_id: i64) -> PathBuf {
    crate::translate::translated_dir(book_id)
}

fn manifest_path(book_id: i64) -> PathBuf {
    artifact_dir(book_id).join("manifest.json")
}

/// The recorded translation of [book_id], if a completed run exists.
pub fn load_artifact(book_id: i64) -> Option<BookTranslation> {
    let raw = std::fs::read_to_string(manifest_path(book_id)).ok()?;
    let t: BookTranslation = serde_json::from_str(&raw).ok()?;
    // A recorded run whose files were evicted/deleted is stale.
    if !std::path::Path::new(&t.mono_path).is_file() {
        return None;
    }
    Some(t)
}

/// Deletes the book's translated artifacts (outputs + manifest).
pub fn clear_artifact(book_id: i64) -> AppResult<()> {
    crate::translate::clear_translation_artifacts(book_id)
}

/// Target language name -> BabelDOC language code (`--lang-out`).
fn lang_code(target: &str) -> String {
    let t = target.trim();
    match t {
        "中文" | "简体中文" | "zh" | "zh-CN" => "zh".into(),
        "繁体中文" | "zh-TW" => "zh-TW".into(),
        "英文" | "English" | "en" => "en".into(),
        "日本語" | "日语" | "ja" => "ja".into(),
        "한국어" | "韩语" | "ko" => "ko".into(),
        "西班牙语" | "es" => "es".into(),
        "法语" | "fr" => "fr".into(),
        "德语" | "de" => "de".into(),
        // 中英互译 resolves per page in the retired pipeline; a whole-book
        // run needs ONE target -- default to Chinese (the dominant use).
        "中英互译" => "zh".into(),
        other if !other.is_empty() => other.to_ascii_lowercase(),
        _ => "zh".into(),
    }
}

struct BookRow {
    stored_path: String,
    page_count: i64,
    title: String,
}

fn load_book_row(book_id: i64) -> AppResult<BookRow> {
    let conn = crate::db::db();
    conn.query_row(
        "SELECT stored_path, page_count, title FROM books WHERE id = ?1",
        rusqlite::params![book_id],
        |row| {
            Ok(BookRow {
                stored_path: row.get(0)?,
                page_count: row.get(1).unwrap_or(0),
                title: row.get(2).unwrap_or_default(),
            })
        },
    )
    .map_err(|_| AppError::NotFound(format!("书籍不存在 (id={book_id})")))
}

/// Runs a whole-book translation, streaming progress. Cancellation kills the
/// engine; failures are reported as a final event carrying the error.
pub async fn translate_book(
    book_id: i64,
    mut on_event: impl FnMut(BookTranslateEvent) + Send + 'static,
) -> AppResult<BookTranslation> {
    if is_running() {
        return Err(AppError::Internal("已有翻译任务进行中".into()));
    }
    if crate::translate::engine::get_engine_status().kind
        != crate::models::translate::EngineStatusKind::Installed
    {
        return Err(AppError::Internal("翻译引擎未安装".into()));
    }
    RUNNING.store(true, Ordering::SeqCst);
    CANCEL.store(false, Ordering::SeqCst);
    crate::translate::mark_translating(book_id);

    let result = tokio::task::spawn_blocking(move || {
        let r = run_job(book_id, &mut on_event);
        // Failure is reported on the stream as a final event (Dart reads
        // `error` from the event -- the sentinel pattern).
        if let Err(e) = &r {
            on_event(BookTranslateEvent {
                phase: "失败".into(),
                detail: e.to_string(),
                done: true,
                error: Some(e.to_string()),
            });
        }
        r
    })
    .await;
    RUNNING.store(false, Ordering::SeqCst);
    crate::translate::unmark_translating(book_id);

    match result {
        Ok(r) => r,
        Err(e) => Err(AppError::Internal(format!("翻译任务失败: {e}"))),
    }
}

fn run_job(
    book_id: i64,
    on_event: &mut impl FnMut(BookTranslateEvent),
) -> AppResult<BookTranslation> {
    let book = load_book_row(book_id)?;
    let ai = crate::translate::load_ai_config_for_job()?;
    if ai.base_url.trim().is_empty() || ai.api_key.trim().is_empty() {
        return Err(AppError::Internal(
            "请先在「AI 设置」中配置 OpenAI 兼容服务（引擎复用该配置）".into(),
        ));
    }
    if !std::path::Path::new(&book.stored_path).is_file() {
        return Err(AppError::Internal("找不到原书文件".into()));
    }

    // Bundled builds ship an offline asset package: restore once when the
    // cache is empty (no network needed).
    let mut emit = |phase: &str, detail: String| {
        on_event(BookTranslateEvent {
            phase: phase.into(),
            detail,
            done: false,
            error: None,
        });
    };
    if let Ok(true) = crate::translate::engine::restore_bundled_assets(&mut |line| {
        emit("准备资产", line)
    }) {
        emit("准备资产", "离线资产已就绪".into());
    }

    let out_dir = artifact_dir(book_id);
    // A fresh run starts from a clean directory: stale outputs from an
    // interrupted run must not be mistaken for this run's results.
    if out_dir.exists() {
        std::fs::remove_dir_all(&out_dir)?;
    }
    std::fs::create_dir_all(&out_dir)?;

    let lang_out = lang_code(&ai.translate_target_lang);
    emit("启动引擎", format!("目标语言 {lang_out}"));

    let mut cmd = Command::new(crate::translate::engine::python_executable());
    let argv = crate::translate::engine::babeldoc_argv();
    cmd.args(argv)
        .args(["--openai"])
        .args(["--openai-base-url", &ai.base_url])
        .args(["--openai-api-key", &ai.api_key])
        .args(["--openai-model", &ai.text_model])
        .args(["--files", &book.stored_path])
        .args(["--lang-out", &lang_out])
        .args(["--output", &out_dir.to_string_lossy()])
        // Attribution lives in the About/settings UI; the produced PDFs stay
        // clean (AGPL does not require the watermark).
        .args(["--watermark-output-mode", "no_watermark"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in crate::translate::engine::python_env() {
        cmd.env(k, v);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| AppError::Internal(format!("无法启动翻译引擎: {e}")))?;

    let (tx, rx) = std::sync::mpsc::channel::<String>();
    if let Some(out) = child.stdout.take() {
        spawn_line_reader(out, tx.clone());
    }
    if let Some(err) = child.stderr.take() {
        spawn_line_reader(err, tx.clone());
    }
    drop(tx);

    let mut phase = "解析版式".to_string();
    let mut tail: Vec<String> = Vec::new();
    let exit_status = loop {
        while let Ok(line) = rx.try_recv() {
            let line = line.trim().to_string();
            if line.is_empty() {
                continue;
            }
            // Coarse phase tracking from the engine's own log lines.
            if line.contains("start to translate") {
                phase = "翻译中".into();
            } else if line.contains("finish translate") {
                phase = "排版输出".into();
            } else if line.contains("parse") && line.contains("pdf") {
                phase = "解析版式".into();
            }
            tail.push(line.clone());
            if tail.len() > 4 {
                tail.remove(0);
            }
            on_event(BookTranslateEvent {
                phase: phase.clone(),
                detail: line,
                done: false,
                error: None,
            });
        }
        if CANCEL.load(Ordering::SeqCst) {
            let _ = child.kill();
            let _ = child.wait();
            CANCEL.store(false, Ordering::SeqCst);
            let _ = std::fs::remove_dir_all(&out_dir);
            return Err(AppError::Internal("翻译已取消".into()));
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(e) => return Err(AppError::Internal(format!("等待引擎失败: {e}"))),
        }
    };
    while let Ok(line) = rx.try_recv() {
        let line = line.trim().to_string();
        if !line.is_empty() {
            tail.push(line);
            if tail.len() > 4 {
                tail.remove(0);
            }
        }
    }
    if !exit_status.success() {
        let _ = std::fs::remove_dir_all(&out_dir);
        return Err(AppError::Internal(format!(
            "引擎退出码 {exit_status}：{}",
            tail.join(" | ")
        )));
    }

    // Locate the produced PDFs (the engine's naming varies with the
    // watermark mode, so scan instead of guessing).
    let (mono, dual) = find_outputs(&out_dir)?;
    let translation = BookTranslation {
        book_id,
        title: book.title,
        target_lang: ai.translate_target_lang.trim().to_string(),
        lang_out: lang_out.clone(),
        mono_path: mono,
        dual_path: dual,
        pages: book.page_count.max(1),
        finished_at: unix_stamp(),
        error: None,
    };
    std::fs::write(
        manifest_path(book_id),
        serde_json::to_string_pretty(&translation)?,
    )?;
    on_event(BookTranslateEvent {
        phase: "完成".into(),
        detail: format!("{} 页已翻译", translation.pages),
        done: true,
        error: None,
    });
    crate::translate::enforce_cache_limit().ok();
    Ok(translation)
}

/// Finds the mono + dual outputs in [dir] (newest wins).
fn find_outputs(dir: &PathBuf) -> AppResult<(String, String)> {
    let mut mono: Option<(std::time::SystemTime, String)> = None;
    let mut dual: Option<(std::time::SystemTime, String)> = None;
    for entry in std::fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        if !name.ends_with(".pdf") {
            continue;
        }
        let mtime = entry
            .metadata()
            .and_then(|m| m.modified())
            .unwrap_or(std::time::UNIX_EPOCH);
        let slot = if name.ends_with(".mono.pdf") {
            &mut mono
        } else if name.ends_with(".dual.pdf") {
            &mut dual
        } else {
            continue;
        };
        let candidate = path.to_string_lossy().to_string();
        match slot {
            Some((t, p)) if *t >= mtime => {
                let _ = p;
            }
            _ => *slot = Some((mtime, candidate)),
        }
    }
    let mono = mono
        .map(|(_, p)| p)
        .ok_or_else(|| AppError::Internal("引擎未产出 mono PDF".into()))?;
    let dual = dual.map(|(_, p)| p).unwrap_or_default();
    Ok((mono, dual))
}

fn unix_stamp() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

fn spawn_line_reader(pipe: impl Read + Send + 'static, tx: std::sync::mpsc::Sender<String>) {
    std::thread::spawn(move || {
        use std::io::BufRead;
        let reader = std::io::BufReader::new(pipe);
        for line in reader.lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lang_mapping_covers_ui_values() {
        assert_eq!(lang_code("中文"), "zh");
        assert_eq!(lang_code("英文"), "en");
        assert_eq!(lang_code("中英互译"), "zh");
        assert_eq!(lang_code("日本語"), "ja");
        assert_eq!(lang_code(""), "zh");
        assert_eq!(lang_code("Klingon"), "klingon");
    }
}