//! Per-page translation pipeline (M7, plan §2/§4/§5 data flow).
//!
//! One atomic `translate_page` run: config load -> cache fast path ->
//! extraction on an INDEPENDENT pdfium handle (OCR fallback for scanned
//! pages, plan §3.5) -> formula-protected batch translation -> coverage /
//! status mapping -> cache write. Progress events flow to the caller's
//! callback, which the api layer adapts to an FRB `StreamSink`.
//!
//! Orchestration (whole-book queues, concurrency, cancellation) is Dart-side
//! (plan §9); this module only ever touches ONE page per call.

use crate::error::{AppError, AppResult};
use crate::models::ai::AiConfig;
use crate::models::translate::{
    PageTranslation, Paragraph, ParagraphKind, ParagraphStatus, TranslatedParagraph,
    TranslationConfig, TranslationProgressEvent,
};
use crate::translate::providers::{provider_from_config, BatchContext, Segment, SegmentResult};
use crate::translate::{cache_key, extract, load_ai_config, load_translation_config};

/// OCR confidence below this marks a paragraph 低置信 (plan §3.5).
const LOW_CONFIDENCE: f64 = 0.8;

/// The book row fields the pipeline needs.
struct BookInfo {
    title: String,
    stored_path: String,
    page_count: i64,
    file_type: String,
}

fn load_book(book_id: i64) -> AppResult<BookInfo> {
    let conn = crate::db::db();
    conn.query_row(
        "SELECT title, stored_path, page_count, file_type FROM books WHERE id = ?1",
        rusqlite::params![book_id],
        |row| {
            Ok(BookInfo {
                title: row.get(0)?,
                stored_path: row.get(1)?,
                page_count: row.get(2)?,
                file_type: row.get(3)?,
            })
        },
    )
    .map_err(|_| AppError::NotFound(format!("书籍不存在 (id={book_id})")))
}

fn event(
    page: i64,
    done: i64,
    total: i64,
    coverage: f64,
    finished: bool,
    error: Option<String>,
) -> TranslationProgressEvent {
    TranslationProgressEvent {
        page,
        done_paragraphs: done,
        total_paragraphs: total,
        coverage,
        finished,
        error,
    }
}

/// Extracts one page's paragraphs for inspection / hashing (pdf feature).
/// Opens its own independent document handle under the pdfium lock.
pub fn extract_paragraphs(book_id: i64, page: i64) -> AppResult<Vec<Paragraph>> {
    let book = load_book(book_id)?;
    if book.file_type != "pdf" {
        return Ok(Vec::new());
    }
    crate::pdf::with_document_file(&book.stored_path, |doc| {
        let neighbors = neighbor_margin_texts(doc, page);
        let outcome = extract::extract_page(doc, page, &neighbors)?;
        let mut paragraphs = outcome.paragraphs;
        if !outcome.has_text_layer {
            // Scan pages without OCR stay empty here; the translate pipeline
            // decides whether to run OCR.
            paragraphs.clear();
        }
        Ok(paragraphs)
    })
}

/// Margin line texts of the adjacent pages, for header/footer detection.
fn neighbor_margin_texts(doc: &pdfium_render::prelude::PdfDocument<'_>, page: i64) -> Vec<String> {
    let count = doc.pages().len() as i64;
    let mut out = Vec::new();
    for p in [page - 1, page + 1] {
        if p >= 1 && p <= count {
            out.extend(extract::margin_line_texts(doc, p).unwrap_or_default());
        }
    }
    out
}

/// Renders a PDF page at original resolution through an independent handle
/// (the OCR input, plan §3.5 / FEATURES 7.1.8).
fn render_page_rgba(
    doc: &pdfium_render::prelude::PdfDocument<'_>,
    page: i64,
) -> AppResult<(Vec<u8>, u32, u32)> {
    use pdfium_render::prelude::*;
    let pg = doc.pages().get((page - 1) as PdfPageIndex)?;
    let w = pg.width().value.max(1.0) as i32;
    let h = pg.height().value.max(1.0) as i32;
    let config = PdfRenderConfig::new().set_target_width(w).set_target_height(h);
    let bitmap = pg.render_with_config(&config)?;
    Ok((
        bitmap.as_rgba_bytes(),
        bitmap.width().max(1) as u32,
        bitmap.height().max(1) as u32,
    ))
}

/// Runs OCR for a page bitmap through the shared engine + page_ocr_cache
/// (plan §3.5: 带缓存).
fn ocr_page(
    book_id: i64,
    page: i64,
    rgba: Vec<u8>,
    width: u32,
    height: u32,
    mode: &str,
) -> AppResult<Vec<crate::ocr::OcrLine>> {
    use crate::ocr::PageImage;
    let conn = crate::db::db();
    if let Ok(Some(cached)) =
        crate::db::repository::ocr::get_page_ocr(&conn, book_id, page, mode)
    {
        return Ok(cached.lines);
    }
    let engine = crate::ocr::engine();
    if !engine.is_available() {
        return Err(AppError::Ocr(crate::ocr::StubOcrEngine::MISSING_MODELS.into()));
    }
    let img = PageImage {
        rgba: &rgba,
        width,
        height,
    };
    let result = engine.scan(&img, mode)?;
    let _ = crate::db::repository::ocr::save_page_ocr(&conn, book_id, page, mode, &result);
    Ok(result.lines)
}

/// Translates one page (1-indexed). `on_event` receives progress updates;
/// the final event always has `finished: true` (with `error` on failure).
pub async fn run_translate_page(
    book_id: i64,
    page: i64,
    force: bool,
    mut on_event: impl FnMut(TranslationProgressEvent),
) -> AppResult<PageTranslation> {
    let book = load_book(book_id)?;
    if page < 1 || (book.page_count > 0 && page > book.page_count) {
        return Err(AppError::NotFound(format!("页码超出范围: {page}")));
    }

    let tc = load_translation_config();
    let ai = load_ai_config();
    let (key_lang, key_provider) = cache_key();

    // Cache fast path (plan §2): an existing row is returned as-is unless a
    // re-translation is forced OR the row predates the current extractor
    // (an extraction fix must not be masked by a stale cache entry).
    {
        let conn = crate::db::db();
        if !force {
            if let Ok(Some(cached)) = crate::db::repository::translate::get_page_translation(
                &conn, book_id, page, &key_lang, &key_provider, true,
            ) {
                if extract::is_current_source_hash(&cached.source_hash) {
                    on_event(event(
                        page,
                        cached.paragraphs.len() as i64,
                        cached.paragraphs.len() as i64,
                        cached.coverage,
                        true,
                        None,
                    ));
                    return Ok(cached);
                }
                tracing::info!(
                    book_id,
                    page,
                    "stale translation cache (extractor changed) -- re-translating"
                );
            }
        }
    }

    crate::translate::mark_translating(book_id);
    let result = translate_page_inner(
        book_id,
        page,
        &book,
        &tc,
        &ai,
        &key_lang,
        &key_provider,
        &mut on_event,
    )
    .await;
    crate::translate::unmark_translating(book_id);
    result
}

#[allow(clippy::too_many_arguments)]
async fn translate_page_inner(
    book_id: i64,
    page: i64,
    book: &BookInfo,
    tc: &TranslationConfig,
    ai: &AiConfig,
    key_lang: &str,
    key_provider: &str,
    on_event: &mut impl FnMut(TranslationProgressEvent),
) -> AppResult<PageTranslation> {
    let provider = match provider_from_config(tc, ai) {
        Ok(p) => p,
        Err(e) => {
            on_event(event(page, 0, 0, 0.0, true, Some(e.to_string())));
            return Err(e);
        }
    };

    // --- extraction (independent handles, serialized under the pdfium lock) --
    // (paragraphs, had_text_layer)
    let (paragraphs, had_text_layer): (Vec<Paragraph>, bool) = match book.file_type.as_str() {
        "pdf" => crate::pdf::with_document_file(&book.stored_path, |doc| {
            let neighbors = neighbor_margin_texts(doc, page);
            let outcome = extract::extract_page(doc, page, &neighbors)?;
            if outcome.has_text_layer {
                Ok((outcome.paragraphs, true))
            } else if tc.auto_ocr {
                let (rgba, w, h) = render_page_rgba(doc, page)?;
                let lines = ocr_page(book_id, page, rgba, w, h, &ai.ocr_mode)?;
                Ok((extract::ocr_lines_to_paragraphs(&lines, page), false))
            } else {
                Err(AppError::Ocr(
                    "扫描页无文字层,且未开启自动 OCR(设置 → 对照阅读)".into(),
                ))
            }
        })?,
        "image" => {
            // Image books are single-page scans (image_book.rs).
            if page != 1 {
                return Err(AppError::NotFound(format!("页码超出范围: {page}")));
            }
            if !tc.auto_ocr {
                let err = "图片书需要 OCR,且未开启自动 OCR(设置 → 对照阅读)";
                on_event(event(page, 0, 0, 0.0, true, Some(err.into())));
                return Err(AppError::Ocr(err.into()));
            }
            let img = image::open(&book.stored_path)
                .map_err(|e| AppError::Internal(format!("decode image: {e}")))?;
            let rgba = img.to_rgba8();
            let (w, h) = (rgba.width(), rgba.height());
            let raw = rgba.into_raw();
            let lines = ocr_page(book_id, 1, raw, w, h, &ai.ocr_mode)?;
            (extract::ocr_lines_to_paragraphs(&lines, page), false)
        }
        other => {
            return Err(AppError::Internal(format!("不支持的书籍类型: {other}")));
        }
    };

    // A text PDF page that yields NO paragraphs is a failure, not an empty
    // page: caching it would permanently skip the page. Report it so the
    // caller can retry (regression: concurrent pdfium calls silently returned
    // zero paragraphs, which used to be cached and skipped forever).
    if paragraphs.is_empty() && had_text_layer {
        let err = "本页未提取到任何文本（可能是渲染/提取异常，请重试）";
        on_event(event(page, 0, 0, 0.0, true, Some(err.into())));
        return Err(AppError::Internal(err.into()));
    }

    if paragraphs.is_empty() {
        // Genuinely blank (no text layer, OCR found nothing): record an
        // empty translation so whole-book queues can skip it forever. The
        // hash is stamped so the row is a valid cache hit next time.
        let translation = PageTranslation {
            page,
            target_lang: effective_target(&ai.translate_target_lang, ""),
            provider: key_provider.to_string(),
            source_hash: extract::stamp_source_hash(""),
            paragraphs: Vec::new(),
            coverage: 1.0,
        };
        let conn = crate::db::db();
        crate::db::repository::translate::save_page_translation(
            &conn, book_id, key_lang, &translation,
        )?;
        on_event(event(page, 0, 0, 1.0, true, None));
        return Ok(translation);
    }

    // --- effective target for 中英互译 (plan §4.5) ------------------------
    let all_text: String = paragraphs
        .iter()
        .map(|p| p.text.as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let effective = effective_target(&ai.translate_target_lang, &all_text);

    // --- source hash over the page's paragraph texts (plan §2), stamped
    // with the extractor version so an algorithm change invalidates old rows.
    let texts: Vec<&str> = paragraphs.iter().map(|p| p.text.as_str()).collect();
    let source_hash = extract::stamp_source_hash(&crate::translate::source_hash(&texts));

    // --- segments: text paragraphs only (formulas stay as images) --------
    // Paragraphs carrying inline formula regions keep their ORIGINAL pixels
    // in the overlay (the drawn replacement would erase the formula
    // graphics), so they are not machine-translated either.
    let segment_idx: Vec<usize> = paragraphs
        .iter()
        .enumerate()
        .filter(|(_, p)| {
            p.kind == ParagraphKind::Text
                && !p.text.trim().is_empty()
                && p.formula_regions.is_empty()
        })
        .map(|(i, _)| i)
        .collect();
    let segments: Vec<Segment> = segment_idx
        .iter()
        .map(|&i| Segment {
            text: paragraphs[i].text.clone(),
            formulas: paragraphs[i].formula_regions.clone(),
        })
        .collect();
    let total = segments.len() as i64;
    on_event(event(page, 0, total, 0.0, false, None));

    // --- glossary (plan §4.4) ---------------------------------------------
    let glossary = {
        let conn = crate::db::db();
        crate::db::repository::translate::list_glossary(&conn)
            .unwrap_or_default()
            .into_iter()
            .filter(|e| {
                let src_ok = match &e.source_lang {
                    Some(l) => l.trim().is_empty() || l == &tc.source_lang,
                    None => true,
                };
                let tgt_ok = match &e.target_lang {
                    Some(l) => l.trim().is_empty() || l == &effective,
                    None => true,
                };
                src_ok && tgt_ok
            })
            .map(|e| (e.source_term, e.target_term))
            .collect::<Vec<_>>()
    };

    let ctx = BatchContext {
        book_title: book.title.clone(),
        target_lang: effective.clone(),
        source_lang: tc.source_lang.clone(),
        prev_paragraph: paragraphs.first().map(|p| p.text.clone()).unwrap_or_default(),
        next_paragraph: paragraphs.last().map(|p| p.text.clone()).unwrap_or_default(),
        glossary,
    };

    // --- translate --------------------------------------------------------
    let results: Vec<SegmentResult> = if segments.is_empty() {
        Vec::new()
    } else {
        match provider.translate_segments(&segments, &ctx).await {
            Ok(r) => r,
            Err(e) => {
                on_event(event(page, 0, total, 0.0, true, Some(e.to_string())));
                return Err(e);
            }
        }
    };

    // --- map back to paragraphs + statuses (plan §4.7/§5) -----------------
    let mut translated = Vec::with_capacity(paragraphs.len());
    let mut seg_pos = 0usize;
    let mut done = 0i64;
    for (i, p) in paragraphs.iter().enumerate() {
        if p.kind == ParagraphKind::Formula {
            // Whole-paragraph formula: the overlay writer keeps the original
            // pixels, never machine-translates it (plan §3.4).
            translated.push(TranslatedParagraph {
                source: p.text.clone(),
                translated: String::new(),
                kind: ParagraphKind::Formula,
                status: ParagraphStatus::Done,
                confidence: p.confidence,
                formula_regions: p.formula_regions.clone(),
                rects: p.rects.clone(),
            });
            continue;
        }
        if segment_idx.get(seg_pos) == Some(&i) {
            let r = &results[seg_pos];
            seg_pos += 1;
            let any_formula_bad = r.formula_ok.iter().any(|ok| !ok);
            let status = if r.failed {
                ParagraphStatus::Failed
            } else if p.confidence < LOW_CONFIDENCE {
                ParagraphStatus::LowConfidence
            } else if any_formula_bad {
                ParagraphStatus::FormulaCheck
            } else {
                ParagraphStatus::Done
            };
            if !r.failed {
                done += 1;
            }
            translated.push(TranslatedParagraph {
                source: p.text.clone(),
                translated: r.text.clone(),
                kind: ParagraphKind::Text,
                status,
                confidence: p.confidence,
                formula_regions: p.formula_regions.clone(),
                rects: p.rects.clone(),
            });
        } else {
            // Non-text, non-formula leftovers (e.g. empty): kept verbatim.
            translated.push(TranslatedParagraph {
                source: p.text.clone(),
                translated: String::new(),
                kind: p.kind,
                status: ParagraphStatus::Done,
                confidence: p.confidence,
                formula_regions: p.formula_regions.clone(),
                rects: p.rects.clone(),
            });
        }
    }
    let coverage = if total == 0 {
        1.0
    } else {
        done as f64 / total as f64
    };

    let translation = PageTranslation {
        page,
        target_lang: effective,
        provider: key_provider.to_string(),
        source_hash,
        paragraphs: translated,
        coverage,
    };
    {
        let conn = crate::db::db();
        crate::db::repository::translate::save_page_translation(
            &conn, book_id, key_lang, &translation,
        )?;
    }
    on_event(event(page, total, total, coverage, true, None));
    Ok(translation)
}

/// 中英互译 resolves per page: CJK-dominant source translates to 英文,
/// otherwise to 中文 (plan §4.5); every other configured language is used
/// as-is.
fn effective_target(configured: &str, page_text: &str) -> String {
    let configured = configured.trim();
    if configured == "中英互译" {
        if extract::cjk_ratio(page_text) > 0.5 {
            "英文".to_string()
        } else {
            "中文".to_string()
        }
    } else if configured.is_empty() {
        "中文".to_string()
    } else {
        configured.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn effective_target_resolves_bilingual_mode_per_page() {
        assert_eq!(effective_target("中文", "anything"), "中文");
        assert_eq!(effective_target("中英互译", "量子力学是物理学分支"), "英文");
        assert_eq!(effective_target("中英互译", "The quick brown fox"), "中文");
        assert_eq!(effective_target("", "x"), "中文");
    }
}
