//! Book-translation job (RetainPDF pipeline sidecar).
//!
//! One whole-book run, two CLI steps of the bundled engine:
//!
//! 1. `normalize-ocr` -- our [`super::flat_ocr`] payload (`generic_flat_ocr`
//!    JSON built from the PDF text layer / local OCR) becomes a validated
//!    `document.v1.json`;
//! 2. `book` -- translate + render in one process, driven by the AI settings'
//!    OpenAI-compatible config (the API key travels via the
//!    `RETAIN_TRANSLATION_API_KEY` env var; the spec only carries a
//!    `credential_ref`, so plaintext keys never land on disk).
//!
//! Progress arrives as stdout JSONL (`pipeline_stage_observation_v1`,
//! `artifact_published`) and is mapped to the pane's coarse phases
//! (解析版式 / 翻译中 / 排版输出). Cancellation kills the running child and
//! removes the job directory. The produced PDF is installed as
//! `translated/{book_id}/translated.pdf` with the usual manifest.
//!
//! v1 scope: whole-book runs, target language fixed to 简体中文 (a RetainPDF
//! pipeline constraint), `render_mode=auto`.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use crate::error::{AppError, AppResult};
use crate::models::translate::{BookTranslateEvent, BookTranslation};

/// A run is in flight (single job at a time; the UI disables the button).
static RUNNING: AtomicBool = AtomicBool::new(false);
static CANCEL: AtomicBool = AtomicBool::new(false);

/// LLM request concurrency for the pipeline (their `workers`; the upstream
/// default of 100 is tuned for server deployments, this is a desktop app).
const TRANSLATION_WORKERS: i64 = 8;

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

fn job_root(book_id: i64) -> PathBuf {
    crate::db::app_data_dir()
        .unwrap_or_default()
        .join("retain_jobs")
        .join(book_id.to_string())
}

/// The recorded translation of [book_id], if a completed run exists.
pub fn load_artifact(book_id: i64) -> Option<BookTranslation> {
    let raw = std::fs::read_to_string(manifest_path(book_id)).ok()?;
    let t: BookTranslation = serde_json::from_str(&raw).ok()?;
    // A recorded run whose files were evicted/deleted is stale.
    if !Path::new(&t.mono_path).is_file() {
        return None;
    }
    Some(t)
}

/// Deletes the book's translated artifacts (outputs + manifest).
pub fn clear_artifact(book_id: i64) -> AppResult<()> {
    crate::translate::clear_translation_artifacts(book_id)
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

/// Glossary rows -> the pipeline's inline entry shape.
fn glossary_entries() -> Vec<serde_json::Value> {
    let conn = crate::db::db();
    let mut out = Vec::new();
    if let Ok(mut stmt) =
        conn.prepare("SELECT source_term, target_term FROM translation_glossary ORDER BY id")
    {
        if let Ok(rows) = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0).unwrap_or_default(),
                row.get::<_, String>(1).unwrap_or_default(),
            ))
        }) {
            for (source, target) in rows.flatten() {
                let source = source.trim().to_string();
                let target = target.trim().to_string();
                if source.is_empty() || target.is_empty() {
                    continue;
                }
                out.push(serde_json::json!({
                    "source": source,
                    "target": target,
                    "level": "preferred",
                }));
            }
        }
    }
    out
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
    if !crate::translate::engine::is_ready() {
        return Err(AppError::Internal(
            "翻译引擎未就绪（缺少内置引擎或组装目录）".into(),
        ));
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
    let root = job_root(book_id);
    let cancelled = CANCEL.load(Ordering::SeqCst);
    let result = run_job_inner(book_id, &root, on_event);
    match &result {
        Ok(_) => cleanup_job_dir(&root, false),
        Err(_) if cancelled || CANCEL.load(Ordering::SeqCst) => cleanup_job_dir(&root, false),
        // Keep the light parts (specs/logs/artifacts) for bug reports.
        Err(_) => cleanup_job_dir(&root, true),
    }
    result
}

fn run_job_inner(
    book_id: i64,
    root: &Path,
    on_event: &mut impl FnMut(BookTranslateEvent),
) -> AppResult<BookTranslation> {
    let book = load_book_row(book_id)?;
    let ai = crate::translate::load_ai_config_for_job()?;
    if ai.base_url.trim().is_empty()
        || ai.api_key.trim().is_empty()
        || ai.text_model.trim().is_empty()
    {
        return Err(AppError::Internal(
            "请先在「AI 设置」中配置 OpenAI 兼容服务（引擎复用该配置）".into(),
        ));
    }
    if !Path::new(&book.stored_path).is_file() {
        return Err(AppError::Internal("找不到原书文件".into()));
    }

    // Bound the persistent engine caches before adding to them.
    crate::translate::enforce_output_cache_cap().ok();

    // --- fresh job directory -------------------------------------------------
    if root.exists() {
        std::fs::remove_dir_all(root)?;
    }
    for sub in [
        "source",
        "ocr/local_raw",
        "ocr/normalized",
        "translated",
        "rendered",
        "artifacts",
        "logs",
        "specs",
    ] {
        std::fs::create_dir_all(root.join(sub))?;
    }
    let source_pdf = root.join("source").join("source.pdf");
    std::fs::copy(&book.stored_path, &source_pdf)
        .map_err(|e| AppError::Internal(format!("复制原书失败: {e}")))?;

    let mut emit = |phase: &str, detail: String| {
        on_event(BookTranslateEvent {
            phase: phase.into(),
            detail,
            done: false,
            error: None,
        });
    };
    emit("解析版式", "提取文字层/扫描页…".into());

    // --- step 0: flat OCR payload (local, no LLM) ---------------------------
    let flat = crate::translate::flat_ocr::build_flat_document(
        source_pdf.to_string_lossy().as_ref(),
        book_id,
        &mut |_done, _total, detail| emit("解析版式", detail),
    )?;
    let payload_path = root.join("ocr/local_raw/payload.json");
    std::fs::write(&payload_path, flat.to_json())?;

    // --- step 1: normalize-ocr -> document.v1.json --------------------------
    let doc_v1 = root.join("ocr/normalized/document.v1.json");
    let normalize_spec = root.join("specs/normalize.spec.json");
    write_json(
        &normalize_spec,
        serde_json::json!({
            "schema_version": "normalize.stage.v1",
            "stage": "normalize",
            "job": {"job_id": job_id(book_id), "job_root": root, "workflow": "book"},
            "inputs": {
                "provider": "generic_flat_ocr",
                "source_json": payload_path,
                "source_pdf": source_pdf,
                "provider_version": "rbwa-flat-1",
            },
        }),
    )?;
    emit("解析版式", "规范化文档结构…".into());
    run_pipeline_step(root, book_id, "normalize-ocr", &normalize_spec, None, on_event)?;
    if !doc_v1.is_file() {
        return Err(AppError::Internal("管线未产出 document.v1.json".into()));
    }

    // --- step 2: book (translate + render) ----------------------------------
    let entries = glossary_entries();
    let inline_count = entries.len();
    let book_spec = root.join("specs/book.spec.json");
    write_json(
        &book_spec,
        serde_json::json!({
            "schema_version": "book.stage.v1",
            "stage": "book",
            "job": {"job_id": job_id(book_id), "job_root": root, "workflow": "book"},
            "inputs": {"source_json": doc_v1, "source_pdf": source_pdf},
            "translation": {
                "base_url": ai.base_url.trim(),
                "model": ai.text_model.trim(),
                "credential_ref": "env:RETAIN_TRANSLATION_API_KEY",
                "mode": "sci",
                "math_mode": "direct_typst",
                "batch_size": 4,
                "classify_batch_size": 12,
                "workers": TRANSLATION_WORKERS,
                "context_mode": "needed",
                "glossary_mode": "matched",
                "memory_mode": "matched",
                "glossary_entries": entries,
                "glossary_inline_entry_count": inline_count,
                "glossary_overridden_entry_count": 0,
                "glossary_resource_entry_count": 0,
                "glossary_name": "",
                "glossary_id": "",
                "rule_profile_name": "general_sci",
                "custom_rules_text": "",
                "skip_title_translation": false,
                "start_page": 0,
                "end_page": -1,
            },
            "render": {
                "render_mode": "auto",
                "translated_pdf_name": "translated.pdf",
                "typst_font_family": "Source Han Serif SC",
                "compile_workers": 2,
            },
        }),
    )?;
    let output_pdf =
        run_pipeline_step(root, book_id, "book", &book_spec, Some(&ai.api_key), on_event)?
            .unwrap_or_default();
    let produced = if !output_pdf.is_empty() && Path::new(&output_pdf).is_file() {
        PathBuf::from(&output_pdf)
    } else {
        newest_pdf(&root.join("rendered"))
            .ok_or_else(|| AppError::Internal("引擎未产出译文 PDF".into()))?
    };

    // --- install artifacts ---------------------------------------------------
    let out_dir = artifact_dir(book_id);
    // A fresh run starts from a clean directory: stale outputs from an
    // interrupted run must not be mistaken for this run's results.
    if out_dir.exists() {
        std::fs::remove_dir_all(&out_dir)?;
    }
    std::fs::create_dir_all(&out_dir)?;
    let dest = out_dir.join("translated.pdf");
    std::fs::copy(&produced, &dest)
        .map_err(|e| AppError::Internal(format!("安装译文 PDF 失败: {e}")))?;
    let translation = BookTranslation {
        book_id,
        title: book.title,
        target_lang: ai.translate_target_lang.trim().to_string(),
        // The pipeline's target language is fixed to 简体中文 (v1 constraint).
        lang_out: "zh".into(),
        mono_path: dest.to_string_lossy().to_string(),
        // Dual/side-by-side output is not produced by this engine path (v1).
        dual_path: String::new(),
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

fn job_id(book_id: i64) -> String {
    format!("book{book_id}-{}", unix_stamp())
}

fn write_json(path: &Path, value: serde_json::Value) -> AppResult<()> {
    std::fs::write(path, serde_json::to_string_pretty(&value)?)?;
    Ok(())
}

/// Removes the job directory after a finished run; on failure the light
/// parts (specs/logs/artifacts) are kept for diagnosis while heavy outputs
/// are dropped. `RBWA_RETAIN_KEEP_JOB=1` keeps everything.
fn cleanup_job_dir(root: &Path, keep_light: bool) {
    if std::env::var("RBWA_RETAIN_KEEP_JOB").is_ok() {
        return;
    }
    if keep_light {
        for heavy in [
            "rendered",
            "translated",
            "ocr",
            "source",
            "tmp",
            "xdg-cache",
            "home",
        ] {
            let _ = std::fs::remove_dir_all(root.join(heavy));
        }
    } else {
        let _ = std::fs::remove_dir_all(root);
    }
}

/// Newest `*.pdf` in [dir] (fallback when no artifact event was parsed).
fn newest_pdf(dir: &Path) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        if path.extension().map(|e| e == "pdf").unwrap_or(false) {
            let mtime = entry
                .metadata()
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            if best.as_ref().map(|(t, _)| mtime > *t).unwrap_or(true) {
                best = Some((mtime, path));
            }
        }
    }
    best.map(|(_, p)| p)
}

// =============================================================================
// Pipeline step runner
// =============================================================================

/// One stdout JSONL observation (`pipeline_stage_observation_v1`) or
/// `artifact_published` record (fields optional: the two record kinds carry
/// different subsets).
#[derive(Debug, Default, serde::Deserialize)]
struct PipelineRecord {
    #[serde(default)]
    schema: String,
    #[serde(default)]
    user_stage: String,
    #[serde(default)]
    stage_detail: String,
    #[serde(default)]
    message: String,
    #[serde(default)]
    event_type: String,
    #[serde(default)]
    progress_current: Option<i64>,
    #[serde(default)]
    progress_total: Option<i64>,
    #[serde(default)]
    payload: serde_json::Value,
}

/// What one parsed stdout line means for the UI.
#[derive(Debug, PartialEq)]
enum LineOutcome {
    None,
    /// A progress update: (user_stage, detail).
    Progress(String, String),
    /// The published output artifact path.
    OutputPdf(String),
}

fn parse_pipeline_line(line: &str) -> LineOutcome {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return LineOutcome::None;
    }
    if let Some(rest) = trimmed.strip_prefix("output pdf:") {
        let path = rest.trim();
        if !path.is_empty() {
            return LineOutcome::OutputPdf(path.to_string());
        }
    }
    if let Ok(rec) = serde_json::from_str::<PipelineRecord>(trimmed) {
        if rec.event_type == "artifact_published" {
            let key = rec
                .payload
                .get("artifact_key")
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            if key == "output_pdf" {
                if let Some(path) = rec.payload.get("path").and_then(|v| v.as_str()) {
                    if !path.is_empty() {
                        return LineOutcome::OutputPdf(path.to_string());
                    }
                }
            }
            return LineOutcome::None;
        }
        if rec.schema == "pipeline_stage_observation_v1" {
            let detail = if !rec.message.is_empty() {
                rec.message.clone()
            } else {
                rec.stage_detail.clone()
            };
            let detail = match (rec.progress_current, rec.progress_total) {
                (Some(c), Some(t)) if t > 0 => format!("{detail}（{c}/{t}）"),
                _ => detail,
            };
            return LineOutcome::Progress(rec.user_stage, detail);
        }
    }
    LineOutcome::None
}

/// Runs one pipeline CLI step (`normalize-ocr` / `book`), streaming progress.
/// Returns the published output PDF path when the step announced one.
fn run_pipeline_step(
    root: &Path,
    book_id: i64,
    command: &str,
    spec_path: &Path,
    api_key: Option<&str>,
    on_event: &mut impl FnMut(BookTranslateEvent),
) -> AppResult<Option<String>> {
    let mut cmd = Command::new(crate::translate::engine::python_executable());
    cmd.args(crate::translate::engine::pipeline_argv())
        .arg(command)
        .arg("--spec")
        .arg(spec_path)
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in crate::translate::engine::runtime_env(root, book_id) {
        cmd.env(k, v);
    }
    if let Some(key) = api_key {
        cmd.env("RETAIN_TRANSLATION_API_KEY", key);
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

    // normalize keeps the leading "解析版式" phase; book moves through
    // translation -> render.
    let mut phase = if command == "book" {
        "翻译中".to_string()
    } else {
        "解析版式".to_string()
    };
    let mut output: Option<String> = None;
    // stdout+stderr share one channel: both feed the diagnostic tail.
    let mut tail: Vec<String> = Vec::new();

    let exit_status = loop {
        while let Ok(line) = rx.try_recv() {
            match parse_pipeline_line(&line) {
                LineOutcome::OutputPdf(path) => output = Some(path),
                LineOutcome::Progress(user_stage, detail) => {
                    if command == "book" {
                        match user_stage.as_str() {
                            "translation" => phase = "翻译中".into(),
                            "render" | "done" => phase = "排版输出".into(),
                            _ => {}
                        }
                    }
                    if !detail.is_empty() {
                        on_event(BookTranslateEvent {
                            phase: phase.clone(),
                            detail,
                            done: false,
                            error: None,
                        });
                    }
                }
                LineOutcome::None => {
                    let t = line.trim();
                    if !t.is_empty() {
                        tail.push(t.to_string());
                        if tail.len() > 8 {
                            tail.remove(0);
                        }
                        // Label lines carry the newest detail for the UI.
                        if t.starts_with("pages processed:")
                            || t.starts_with("effective render mode:")
                            || t.starts_with("total time:")
                        {
                            on_event(BookTranslateEvent {
                                phase: phase.clone(),
                                detail: t.to_string(),
                                done: false,
                                error: None,
                            });
                        }
                    }
                }
            }
        }
        if CANCEL.load(Ordering::SeqCst) {
            kill_child(&mut child);
            return Err(AppError::Internal("翻译已取消".into()));
        }
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(e) => return Err(AppError::Internal(format!("等待引擎失败: {e}"))),
        }
    };
    while let Ok(line) = rx.try_recv() {
        if let LineOutcome::OutputPdf(path) = parse_pipeline_line(&line) {
            output = Some(path);
        }
        let t = line.trim();
        if !t.is_empty() {
            tail.push(t.to_string());
            if tail.len() > 8 {
                tail.remove(0);
            }
        }
    }
    if !exit_status.success() {
        let summary = structured_failure_summary(&tail).unwrap_or_else(|| tail.join(" | "));
        return Err(AppError::Internal(format!(
            "引擎退出码 {exit_status}：{summary}"
        )));
    }
    Ok(output)
}

fn kill_child(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

/// The pipeline prints a machine-readable failure line. Its `summary` is
/// often the useless "任务失败，但暂未识别出明确根因" while the real cause
/// lives in `detail` (e.g. the review-gate item list), so prefer `detail`.
fn structured_failure_summary(lines: &[String]) -> Option<String> {
    for line in lines.iter().rev() {
        if let Some(rest) = line.split("structured failure json:").nth(1) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(rest.trim()) {
                let field = |key: &str| {
                    v.get(key)
                        .and_then(|s| s.as_str())
                        .unwrap_or_default()
                        .trim()
                        .to_string()
                };
                let summary = field("summary");
                let detail = field("detail");
                let code = field("failure_code");
                let stage = field("failed_stage");
                let message = if !detail.is_empty() && detail != summary {
                    detail
                } else {
                    summary
                };
                let prefix = format!("{stage}/{code}");
                let joined = if message.is_empty() {
                    prefix
                } else {
                    format!("{prefix}: {message}")
                };
                let joined = joined.trim_matches(['/', ':', ' ']).to_string();
                if !joined.is_empty() {
                    return Some(truncate_chars(&joined, 400));
                }
            }
        }
    }
    None
}

/// Char-boundary-safe truncation for error messages (Chinese text).
fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max).collect();
    out.push('…');
    out
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

fn unix_stamp() -> String {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs().to_string())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_id_is_book_scoped() {
        let id = job_id(7);
        assert!(id.starts_with("book7-"), "{id}");
    }

    #[test]
    fn pipeline_line_parser_reads_observations_and_artifacts() {
        let obs = r#"{"job_id":"j","seq":3,"ts":"t","schema":"pipeline_stage_observation_v1","schema_version":1,"user_stage":"translation","stage":"translating","stage_detail":"翻译中","message":"批次翻译","event_type":"stage_progress","progress_current":4,"progress_total":10,"payload":{}}"#;
        assert_eq!(
            parse_pipeline_line(obs),
            LineOutcome::Progress("translation".into(), "批次翻译（4/10）".into())
        );
        let art = r#"{"job_id":"j","seq":9,"event_type":"artifact_published","payload":{"artifact_key":"output_pdf","path":"/tmp/x/translated.pdf"}}"#;
        assert_eq!(
            parse_pipeline_line(art),
            LineOutcome::OutputPdf("/tmp/x/translated.pdf".into())
        );
        assert_eq!(parse_pipeline_line("output pdf: /tmp/y.pdf"), LineOutcome::OutputPdf("/tmp/y.pdf".into()));
        assert_eq!(parse_pipeline_line("random noise"), LineOutcome::None);
        assert_eq!(parse_pipeline_line(""), LineOutcome::None);
    }

    #[test]
    fn failure_summary_extracts_structured_json() {
        let lines = vec![
            "some log".to_string(),
            r#"structured failure json: {"failed_stage":"render","failure_code":"typst_failed","summary":"compile error"}"#.to_string(),
        ];
        let s = structured_failure_summary(&lines).unwrap();
        assert!(s.contains("render") && s.contains("typst_failed") && s.contains("compile error"));
        assert!(structured_failure_summary(&["nothing".into()]).is_none());
    }

    /// The generic upstream summary must not hide the real cause: `detail`
    /// wins whenever it says something else.
    #[test]
    fn failure_summary_prefers_detail_over_generic_summary() {
        let lines = vec![
            r#"structured failure json: {"failed_stage":"translation","failure_code":"python_unhandled_exception","summary":"任务失败，但暂未识别出明确根因","detail":"translation review gate blocked: review_error_count=6 preview=p3:p003-b000:truncated_translation"}"#.to_string(),
        ];
        let s = structured_failure_summary(&lines).unwrap();
        assert!(s.contains("review gate blocked"), "{s}");
        assert!(!s.contains("未识别出明确根因"), "{s}");
    }

    // =========================================================================
    // End-to-end (dev only): real Python pipeline + mock LLM, zero API calls.
    // =========================================================================

    /// Resolves the assembled engine directory (env or `<repo>/engine-dev/retainpdf`).
    fn resolve_engine_dir() -> Option<PathBuf> {
        if let Ok(dir) = std::env::var("RBWA_RETAIN_ENGINE_DIR") {
            let p = PathBuf::from(dir);
            if p.join("engine.json").is_file() {
                return Some(p);
            }
        }
        for base in [PathBuf::from(".."), PathBuf::from(".")] {
            let p = base.join("engine-dev/retainpdf");
            if p.join("engine.json").is_file() {
                return Some(p.canonicalize().unwrap_or(p));
            }
        }
        None
    }

    /// Locates `scripts/dev/mock_llm.py` relative to the crate (cwd = rust/).
    fn resolve_mock_script() -> Option<PathBuf> {
        for base in [PathBuf::from(".."), PathBuf::from(".")] {
            let p = base.join("scripts/dev/mock_llm.py");
            if p.is_file() {
                return Some(p.canonicalize().unwrap_or(p));
            }
        }
        None
    }

    fn free_port() -> u16 {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind :0");
        listener.local_addr().expect("addr").port()
    }

    /// Builds a two-page English text PDF for the fixture.
    fn build_fixture_pdf(path: &Path) {
        use pdfium_render::prelude::*;
        crate::pdf::with_pdfium_lock(|p| {
            let mut doc = p.create_new_pdf()?;
            let font = doc.fonts_mut().helvetica();
            {
                let mut page = doc.pages_mut().create_page_at_end(PdfPagePaperSize::a4())?;
                let objs = page.objects_mut();
                objs.create_text_object(
                    PdfPoints::new(170.0),
                    PdfPoints::new(700.0),
                    "A Study of Layout-Preserving Translation",
                    font,
                    PdfPoints::new(16.0),
                )?;
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(650.0),
                    "Machine translation of scientific papers must preserve the original layout.",
                    font,
                    PdfPoints::new(11.0),
                )?;
            }
            {
                let mut page = doc.pages_mut().create_page_at_end(PdfPagePaperSize::a4())?;
                let objs = page.objects_mut();
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(700.0),
                    "2. Method",
                    font,
                    PdfPoints::new(14.0),
                )?;
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(660.0),
                    "We render translated text with Typst over the page background.",
                    font,
                    PdfPoints::new(11.0),
                )?;
            }
            doc.save_to_file(path)?;
            Ok(())
        })
        .expect("build fixture pdf");
    }

    /// Full job run: temp DB + fixture book + mock LLM + the real pipeline.
    ///
    /// ```text
    /// cargo test --all-features -- --ignored translate_book_end_to_end
    /// ```
    #[test]
    #[ignore = "dev e2e: needs python3 + an assembled engine (RBWA_RETAIN_ENGINE_DIR or engine-dev/)"]
    fn translate_book_end_to_end() {
        let Some(engine) = resolve_engine_dir() else {
            panic!("engine dir not found (set RBWA_RETAIN_ENGINE_DIR or build engine-dev/)");
        };
        let Some(mock_script) = resolve_mock_script() else {
            panic!("scripts/dev/mock_llm.py not found");
        };
        // Safety: this ignored test is meant to run as the single test in its
        // process (`--ignored translate_book_end_to_end`); env mutation is
        // then race-free.
        unsafe {
            std::env::set_var("RBWA_RETAIN_ENGINE_DIR", &engine);
        }

        let tmp = std::env::temp_dir().join(format!("rbwa_e2e_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("tmp dir");
        crate::db::init_database_at(&tmp.join("rbwa.db")).expect("init db");

        // RBWA_E2E_BOOK_PDF: use an external PDF (scale diagnosis) instead of
        // the tiny built-in fixture.
        let book_pdf = tmp.join("book.pdf");
        let mut fixture_pages = 2i64;
        match std::env::var("RBWA_E2E_BOOK_PDF") {
            Ok(src) => {
                std::fs::copy(&src, &book_pdf).expect("copy external pdf");
                fixture_pages = crate::pdf::with_document_file(book_pdf.to_str().unwrap(), |doc| {
                    Ok(doc.pages().len() as i64)
                })
                .expect("count pages");
            }
            Err(_) => build_fixture_pdf(&book_pdf),
        }

        // Book row.
        let conn = crate::db::db();
        conn.execute(
            "INSERT INTO books (title, original_path, stored_path, file_type, page_count) \
             VALUES (?1, ?2, ?3, 'pdf', ?4)",
            rusqlite::params![
                "端到端测试书",
                book_pdf.to_string_lossy(),
                book_pdf.to_string_lossy(),
                fixture_pages
            ],
        )
        .expect("insert book");
        let book_id: i64 = conn.last_insert_rowid();
        drop(conn);

        // Mock LLM only: this harness must never call a real endpoint (real
        // API runs are the user's decision, not a test's).
        let port = free_port();
        let mut mock = Command::new("python3")
            .arg(&mock_script)
            .arg("--port")
            .arg(port.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn mock llm");
        for _ in 0..50 {
            if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }

        // AI settings pointing at the mock.
        {
            let conn = crate::db::db();
            let ai = serde_json::json!({
                "base_url": format!("http://127.0.0.1:{port}/v1"),
                "api_key": "mock-key",
                "text_model": "mock-model",
                "translate_target_lang": "中文",
            });
            conn.execute(
                "INSERT INTO settings (key, value) VALUES ('ai_config', ?1) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![ai.to_string()],
            )
            .expect("save ai config");
        }

        // Run the job on a current-thread runtime.
        let events: std::sync::Arc<std::sync::Mutex<Vec<BookTranslateEvent>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = events.clone();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let result = rt.block_on(translate_book(book_id, move |ev| {
            sink.lock().unwrap().push(ev);
        }));
        let _ = mock.kill();
        let _ = mock.wait();

        let translation = result.expect("translation finished");
        let mono = PathBuf::from(&translation.mono_path);
        assert!(mono.is_file(), "mono pdf missing: {}", mono.display());
        assert!(manifest_path(book_id).is_file(), "manifest missing");

        // Page count 1:1 and mock Chinese text present in the produced PDF.
        let pages = crate::pdf::with_document_file(&translation.mono_path, |doc| {
            Ok(doc.pages().len() as i64)
        })
        .expect("open produced pdf");
        assert_eq!(pages, fixture_pages, "page count must match the source");
        let texts = crate::pdf::extract_document_text(&translation.mono_path).expect("extract text");
        assert!(
            texts.first().map(|t| t.contains("模拟译文")).unwrap_or(false),
            "translated text missing: {:?}",
            texts.first()
        );

        // Events carry a terminal success and passed through 翻译中.
        let events = events.lock().unwrap();
        assert!(
            events.iter().any(|e| e.phase == "翻译中"),
            "no 翻译中 phase: {:?}",
            events.iter().map(|e| &e.phase).collect::<Vec<_>>()
        );
        let last = events.last().expect("events");
        assert!(last.done && last.error.is_none(), "terminal event: {last:?}");

        if std::env::var("RBWA_KEEP_E2E").is_err() {
            let _ = std::fs::remove_dir_all(&tmp);
        } else {
            eprintln!("kept e2e artifacts at {}", tmp.display());
        }
    }

    /// Scanned-book variant: an image-only PDF goes through the local OCR path
    /// (PP-OCRv4 via the app-data `models/`) into the same pipeline.
    ///
    /// ```text
    /// cargo test --all-features -- --ignored translate_book_scanned_end_to_end
    /// ```
    #[test]
    #[ignore = "dev e2e: needs python3 + engine + OCR models (RBWA_OCR_MODELS_SRC)"]
    fn translate_book_scanned_end_to_end() {
        let Some(engine) = resolve_engine_dir() else {
            panic!("engine dir not found (set RBWA_RETAIN_ENGINE_DIR or build engine-dev/)");
        };
        let Some(mock_script) = resolve_mock_script() else {
            panic!("scripts/dev/mock_llm.py not found");
        };
        let models_src = std::env::var("RBWA_OCR_MODELS_SRC")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                PathBuf::from(std::env::var("HOME").unwrap_or_default())
                    .join(".local/share/RBWA/models")
            });
        if !models_src.join("high_precision").is_dir() {
            panic!("OCR models not found at {} (set RBWA_OCR_MODELS_SRC)", models_src.display());
        }
        unsafe {
            std::env::set_var("RBWA_RETAIN_ENGINE_DIR", &engine);
        }

        let tmp = std::env::temp_dir().join(format!("rbwa_e2e_scan_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("tmp dir");
        crate::db::init_database_at(&tmp.join("rbwa.db")).expect("init db");
        // The OCR engine resolves models under {data_dir}/models.
        std::os::unix::fs::symlink(&models_src, tmp.join("models")).expect("link models");

        // 1. A text PDF built with pdfium, then rasterized into an image-only
        //    (scanned-style) PDF by the engine's PyMuPDF.
        let text_pdf = tmp.join("text.pdf");
        build_fixture_pdf(&text_pdf);
        let scanned_pdf = tmp.join("scanned.pdf");
        let rasterize = Command::new(engine.join("python").join("bin").join("python3.11"))
            .arg("-c")
            .arg(
                "import fitz,sys\n\
                 src,dst=sys.argv[1],sys.argv[2]\n\
                 d=fitz.open(src); out=fitz.open()\n\
                 for p in d:\n\
                 \x20   pix=p.get_pixmap(dpi=150)\n\
                 \x20   np=out.new_page(width=p.rect.width,height=p.rect.height)\n\
                 \x20   np.insert_image(np.rect,pixmap=pix)\n\
                 out.save(dst)\n",
            )
            .arg(&text_pdf)
            .arg(&scanned_pdf)
            .env("PYTHONPATH", engine.join("site-packages"))
            .output()
            .expect("rasterize");
        assert!(
            scanned_pdf.is_file(),
            "rasterize failed: {}",
            String::from_utf8_lossy(&rasterize.stderr)
        );

        let conn = crate::db::db();
        conn.execute(
            "INSERT INTO books (title, original_path, stored_path, file_type, page_count) \
             VALUES (?1, ?2, ?3, 'pdf', 2)",
            rusqlite::params![
                "扫描版端到端",
                scanned_pdf.to_string_lossy(),
                scanned_pdf.to_string_lossy()
            ],
        )
        .expect("insert book");
        let book_id: i64 = conn.last_insert_rowid();
        drop(conn);

        let port = free_port();
        let mut mock = Command::new("python3")
            .arg(&mock_script)
            .arg("--port")
            .arg(port.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn mock llm");
        for _ in 0..50 {
            if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        {
            let conn = crate::db::db();
            let ai = serde_json::json!({
                "base_url": format!("http://127.0.0.1:{port}/v1"),
                "api_key": "mock-key",
                "text_model": "mock-model",
                "translate_target_lang": "中文",
            });
            conn.execute(
                "INSERT INTO settings (key, value) VALUES ('ai_config', ?1) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![ai.to_string()],
            )
            .expect("save ai config");
        }

        let events: std::sync::Arc<std::sync::Mutex<Vec<BookTranslateEvent>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = events.clone();
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let result = rt.block_on(translate_book(book_id, move |ev| {
            sink.lock().unwrap().push(ev);
        }));
        let _ = mock.kill();
        let _ = mock.wait();

        let translation = result.expect("scanned translation finished");
        let pages = crate::pdf::with_document_file(&translation.mono_path, |doc| {
            Ok(doc.pages().len() as i64)
        })
        .expect("open produced pdf");
        assert_eq!(pages, 2, "page count must match the scanned source");
        let texts = crate::pdf::extract_document_text(&translation.mono_path).expect("extract text");
        assert!(
            texts.first().map(|t| t.contains("模拟译文")).unwrap_or(false),
            "OCR path translation missing: {:?}",
            texts.first()
        );
        let events = events.lock().unwrap();
        assert!(
            events.iter().any(|e| e.phase == "解析版式" && e.detail.contains("识别扫描页")),
            "no scanned-page OCR progress: {:?}",
            events.iter().map(|e| &e.detail).collect::<Vec<_>>()
        );

        if std::env::var("RBWA_KEEP_E2E").is_err() {
            let _ = std::fs::remove_dir_all(&tmp);
        } else {
            eprintln!("kept scanned e2e artifacts at {}", tmp.display());
        }
    }

    /// Cancellation: a slow mock keeps the run alive while `cancel()` fires;
    /// the job must stop, clean up and report 取消.
    ///
    /// ```text
    /// cargo test --all-features -- --ignored translate_book_cancel
    /// ```
    #[test]
    #[ignore = "dev e2e: needs python3 + an assembled engine"]
    fn translate_book_cancel_mid_run() {
        let Some(engine) = resolve_engine_dir() else {
            panic!("engine dir not found (set RBWA_RETAIN_ENGINE_DIR or build engine-dev/)");
        };
        let Some(mock_script) = resolve_mock_script() else {
            panic!("scripts/dev/mock_llm.py not found");
        };
        unsafe {
            std::env::set_var("RBWA_RETAIN_ENGINE_DIR", &engine);
        }

        let tmp = std::env::temp_dir().join(format!("rbwa_e2e_cancel_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(&tmp).expect("tmp dir");
        crate::db::init_database_at(&tmp.join("rbwa.db")).expect("init db");

        let book_pdf = tmp.join("book.pdf");
        build_fixture_pdf(&book_pdf);
        let conn = crate::db::db();
        conn.execute(
            "INSERT INTO books (title, original_path, stored_path, file_type, page_count) \
             VALUES (?1, ?2, ?3, 'pdf', 2)",
            rusqlite::params!["取消测试", book_pdf.to_string_lossy(), book_pdf.to_string_lossy()],
        )
        .expect("insert book");
        let book_id: i64 = conn.last_insert_rowid();
        drop(conn);

        // 5s per reply: the (parallel) requests still keep the run busy long
        // enough for the canceller to fire mid-step.
        let port = free_port();
        let mut mock = Command::new("python3")
            .arg(&mock_script)
            .arg("--port")
            .arg(port.to_string())
            .arg("--delay")
            .arg("5")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn mock llm");
        for _ in 0..50 {
            if std::net::TcpStream::connect(("127.0.0.1", port)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        {
            let conn = crate::db::db();
            let ai = serde_json::json!({
                "base_url": format!("http://127.0.0.1:{port}/v1"),
                "api_key": "mock-key",
                "text_model": "mock-model",
                "translate_target_lang": "中文",
            });
            conn.execute(
                "INSERT INTO settings (key, value) VALUES ('ai_config', ?1) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                rusqlite::params![ai.to_string()],
            )
            .expect("save ai config");
        }

        let canceller = std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(2));
            cancel();
        });
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("runtime");
        let result = rt.block_on(translate_book(book_id, |_| {}));
        let _ = canceller.join();
        let _ = mock.kill();
        let _ = mock.wait();

        let err = result.expect_err("cancelled run must fail");
        assert!(err.to_string().contains("取消"), "unexpected error: {err}");
        assert!(load_artifact(book_id).is_none(), "no artifact after cancel");
        assert!(!is_running(), "RUNNING flag must be cleared");

        if std::env::var("RBWA_KEEP_E2E").is_err() {
            let _ = std::fs::remove_dir_all(&tmp);
        }
    }
}