//! Paragraph extraction for bilingual reading (M7, `docs/BILINGUAL_READING_PLAN.md` §3).
//!
//! All PDF work here runs against an INDEPENDENT document handle opened from
//! the book's `stored_path` (the caller owns it) -- never the reader's global
//! `DOC` lock -- so whole-book extraction and formula capture never block
//! page rendering (plan §3.0).
//!
//! Pipeline per page (plan §3.1-§3.5):
//!   1. paragraph reconstruction: baseline y clustering into lines, optional
//!      two-column split, gap/indent-based paragraph merge with hyphen
//!      restoration and ligature normalization. NOTE: the plan's preferred
//!      `PdfParagraph::from_objects()` path is NOT importable from outside
//!      pdfium-render 0.9.3/0.9.4 (the `pdf` module is private and the
//!      prelude does not re-export the type), so this baseline path -- the
//!      plan's designated fallback -- is the primary implementation;
//!   2. noise removal: margin-positioned short lines that look like page
//!      numbers or repeat on adjacent pages (headers/footers);
//!   3. formula detection from font metadata (math font families, symbolic
//!      fonts, sub/superscript scaling, rotation) with region images
//!      captured from the original page;
//!   4. OCR line merging for scanned pages (the caller runs the engine and
//!      feeds [OcrLine]s into [ocr_lines_to_paragraphs]).
//!
//! Pages are 1-indexed everywhere in this module (plan §2).

use pdfium_render::prelude::*;

use crate::error::AppResult;
use crate::models::annotation::NormRect;
use crate::models::translate::{FormulaRegion, Paragraph, ParagraphKind};
use crate::ocr::OcrLine;

/// Vertical fraction of the page counted as header/footer margin.
const MARGIN_FRACTION: f64 = 0.08;
/// A margin line longer than this is treated as content, not noise.
const MAX_NOISE_CHARS: usize = 80;

/// Version of the paragraph-extraction algorithm. Bumped whenever extraction,
/// noise removal or formula detection changes in a way that makes previously
/// cached translations stale (the cache fast-path and the resume count reject
/// rows stamped with an older version, so a fix takes effect on
/// already-translated books instead of being masked by the cache).
/// The stamp helpers live in [`crate::translate`] (always compiled).
pub use crate::translate::{is_current_source_hash, stamp_source_hash, EXTRACTOR_VERSION};

/// A page character with geometry + font metadata for formula detection
/// (plan §3.4). Box is normalized [0,1], top-left origin (Flutter space).
#[derive(Debug, Clone)]
pub struct PageChar {
    pub ch: String,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub font_name: String,
    pub is_symbolic: bool,
    pub scaled_size: f64,
    pub unscaled_size: f64,
    pub angle: f64,
    pub is_hyphen: bool,
}

/// Result of extracting one page.
#[derive(Debug, Default)]
pub struct ExtractOutcome {
    /// Noise (headers/footers/page numbers) is already excluded.
    pub paragraphs: Vec<Paragraph>,
    /// False for scanned pages with no text layer (caller decides on OCR).
    pub has_text_layer: bool,
}

/// Collects chars + font metadata for one page (1-indexed).
pub fn collect_page_chars(doc: &PdfDocument<'_>, page: i64) -> AppResult<Vec<PageChar>> {
    let pg = doc.pages().get((page - 1) as PdfPageIndex)?;
    let page_w = pg.width().value.max(1.0) as f64;
    let page_h = pg.height().value.max(1.0) as f64;
    let text = pg.text()?;
    let mut out = Vec::new();
    for char in text.chars().iter() {
        let ch = char.unicode_string().unwrap_or_default();
        if ch.is_empty() {
            continue;
        }
        let Ok(rect) = char.tight_bounds() else {
            continue;
        };
        // tight_bounds -> quad points for left/bottom/width/height (same
        // normalization as pdf::pdfium::extract_text, y flipped for Flutter).
        let quad = rect.to_quad_points();
        let quad_w = quad.width().value as f64;
        let quad_h = quad.height().value as f64;
        let bottom = quad.bottom().value as f64;
        let left = quad.left().value as f64;
        out.push(PageChar {
            ch,
            x: (left / page_w).max(0.0),
            y: (1.0 - (bottom + quad_h) / page_h).clamp(0.0, 1.0),
            w: (quad_w / page_w).max(0.0),
            h: (quad_h / page_h).max(0.0),
            font_name: char.font_name(),
            is_symbolic: char.font_is_symbolic(),
            scaled_size: char.scaled_font_size().value as f64,
            unscaled_size: char.unscaled_font_size().value as f64,
            angle: char.angle_degrees().unwrap_or(0.0) as f64,
            is_hyphen: char.is_hyphen().unwrap_or(false),
        });
    }
    Ok(out)
}

/// Normalized margin-band line texts of a page, for cross-page noise
/// comparison (plan §3.3). Cheap: chars -> lines -> margin filter.
pub fn margin_line_texts(doc: &PdfDocument<'_>, page: i64) -> AppResult<Vec<String>> {
    let chars = collect_page_chars(doc, page)?;
    Ok(cluster_lines(&chars)
        .into_iter()
        .filter(|l| in_margin(&l.rect))
        .map(|l| normalize_ws(&l.text))
        .collect())
}

/// Extracts one page (1-indexed) of an open independent document.
///
/// `neighbors` holds the margin line texts of the adjacent pages (for
/// header/footer repetition detection); empty for standalone use.
pub fn extract_page(
    doc: &PdfDocument<'_>,
    page: i64,
    neighbors: &[String],
) -> AppResult<ExtractOutcome> {
    // Kept for the page-range validation (out-of-range pages error here).
    let _pg = doc.pages().get((page - 1) as PdfPageIndex)?;
    let chars = collect_page_chars(doc, page)?;
    if chars.iter().all(|c| c.ch.trim().is_empty()) {
        return Ok(ExtractOutcome {
            paragraphs: Vec::new(),
            has_text_layer: false,
        });
    }

    // --- paragraph reconstruction (baseline clustering; see module docs) --
    let raw = fallback_paragraphs(&chars, page);
    if raw.is_empty() {
        return Ok(ExtractOutcome {
            paragraphs: Vec::new(),
            has_text_layer: true,
        });
    }

    // --- noise removal (plan §3.3) ----------------------------------------
    let paragraphs: Vec<Paragraph> = raw
        .into_iter()
        .filter(|p| !is_noise(&p.text, paragraph_rect(p), neighbors))
        .collect();

    // --- formula detection (plan §3.4) ------------------------------------
    // Whole-paragraph formulas are NOT machine-translated; the overlay writer
    // keeps the original page pixels at their position, so no region image is
    // captured anymore.
    let signals = math_signals(&chars);
    let regions = detect_formula_regions(&chars, &signals);
    let paragraphs = attach_formulas(paragraphs, &chars, &signals, &regions);

    Ok(ExtractOutcome {
        paragraphs,
        has_text_layer: true,
    })
}

// =============================================================================
// Baseline paragraph reconstruction (plan §3.1; promoted to primary -- see
// module docs) + OCR merging (§3.5)
// =============================================================================

/// One clustered text line.
#[derive(Debug, Clone)]
struct Line {
    text: String,
    rect: NormRect,
    ends_hyphen: bool,
}

/// Groups chars into lines by baseline proximity. Chars arrive in content
/// order; each lands on the existing line whose center y is within half a
/// line height, else starts a new line. Lines are then sorted top-to-bottom
/// and their chars left-to-right.
fn cluster_lines(chars: &[PageChar]) -> Vec<Line> {
    // (char indices, center_y of the first char, height of the first char)
    let mut groups: Vec<(Vec<usize>, f64, f64)> = Vec::new();
    for (i, c) in chars.iter().enumerate() {
        // Line-break control chars carry no text (pdfium reports them as
        // separate chars): drop them so they do not add stray spaces.
        if c.ch == "\r" || c.ch == "\n" || c.ch == "\u{0}" {
            continue;
        }
        let cy = c.y + c.h / 2.0;
        if c.ch.trim().is_empty() {
            // Space glyphs sit slightly off the baseline, so a strict
            // tolerance would strand them; attach to the vertically nearest
            // line instead.
            if let Some((g, _, _)) = groups.iter_mut().min_by(|a, b| {
                (cy - a.1)
                    .abs()
                    .partial_cmp(&(cy - b.1).abs())
                    .unwrap_or(std::cmp::Ordering::Equal)
            }) {
                g.push(i);
            }
            continue;
        }
        let target = groups
            .iter_mut()
            .filter(|(_, gcy, gh)| (cy - gcy).abs() < (gh * 0.6).max(0.004))
            .max_by_key(|(g, _, _)| g.len());
        match target {
            Some(g) => g.0.push(i),
            None => groups.push((vec![i], cy, c.h.max(0.004))),
        }
    }

    let mut lines: Vec<Line> = groups
        .into_iter()
        .map(|(idxs, _, _)| {
            let mut sorted = idxs;
            sorted.sort_by(|&a, &b| {
                chars[a]
                    .x
                    .partial_cmp(&chars[b].x)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let mut text = String::new();
            let mut x0: f64 = f64::MAX;
            let mut y0: f64 = f64::MAX;
            let mut x1: f64 = 0.0;
            let mut y1: f64 = 0.0;
            let mut ends_hyphen = false;
            for &i in &sorted {
                let c = &chars[i];
                if c.ch.trim().is_empty() {
                    // Leading indent whitespace is ignored.
                    if text.is_empty() {
                        continue;
                    }
                    // Keep single spaces between words; collapse runs.
                    if !text.ends_with(' ') {
                        text.push(' ');
                    }
                    continue;
                }
                text.push_str(&c.ch);
                ends_hyphen = c.is_hyphen || c.ch == "-" || c.ch == "‐";
                x0 = x0.min(c.x);
                y0 = y0.min(c.y);
                x1 = x1.max(c.x + c.w);
                y1 = y1.max(c.y + c.h);
            }
            // Trailing spaces from the loop above are trimmed by normalize.
            Line {
                text: text.trim_end().to_string(),
                rect: NormRect {
                    x: x0,
                    y: y0,
                    w: (x1 - x0).max(0.0),
                    h: (y1 - y0).max(0.0),
                },
                ends_hyphen,
            }
        })
        .filter(|l| !l.text.trim().is_empty())
        .collect();
    lines.sort_by(|a, b| {
        a.rect
            .y
            .partial_cmp(&b.rect.y)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    lines
}

/// Merges clustered lines into paragraphs: gap + first-line-indent rules,
/// with an optional two-column split (plan §3.1 回退路径). Display-math lines
/// (narrow, horizontally centered) are split off into their own paragraphs so
/// the formula classifier sees them standalone instead of merged into the
/// surrounding prose.
fn fallback_paragraphs(chars: &[PageChar], page: i64) -> Vec<Paragraph> {
    let lines = cluster_lines(chars);
    if lines.is_empty() {
        return Vec::new();
    }
    let ordered = order_for_reading(&lines);
    let mut heights: Vec<f64> = ordered.iter().map(|l| l.rect.h).collect();
    let median_h = median(&mut heights).unwrap_or(0.02).max(0.005);

    // Wide-line reference + per-line display-math flag (same shape rule as
    // is_whole_paragraph_formula rule 3).
    let mut line_ws: Vec<f64> = ordered.iter().map(|l| l.rect.w).filter(|w| *w > 0.0).collect();
    line_ws.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let wide_p95 = line_ws
        .get(line_ws.len().saturating_sub(1).min(line_ws.len() * 95 / 100))
        .copied()
        .unwrap_or(1.0);
    let display_flag = |l: &Line| -> (bool, f64) {
        let cx = l.rect.x + l.rect.w / 2.0;
        let centered = [0.25, 0.5, 0.75]
            .iter()
            .any(|c| (cx - c).abs() <= 0.06);
        (l.rect.w <= wide_p95 * 0.7 && centered, cx)
    };

    let mut paragraphs: Vec<Paragraph> = Vec::new();
    let mut current: Vec<Line> = Vec::new();
    let flush = |current: &mut Vec<Line>, paragraphs: &mut Vec<Paragraph>| {
        if current.is_empty() {
            return;
        }
        let text = join_paragraph_text(current);
        if !text.trim().is_empty() {
            paragraphs.push(Paragraph {
                text,
                rects: current.iter().map(|l| l.rect).collect(),
                page,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            });
        }
        current.clear();
    };

    for line in ordered {
        let (narrow, cx) = display_flag(&line);
        if let Some(prev) = current.last() {
            let (prev_narrow, prev_cx) = display_flag(prev);
            let gap = line.rect.y - (prev.rect.y + prev.rect.h);
            let indented = line.rect.x > prev.rect.x + 0.03;
            // Break on the usual gap/indent rules, on a prose<->display-math
            // transition, or between two different display blocks.
            let math_boundary = narrow != prev_narrow
                || (narrow && (cx - prev_cx).abs() > 0.05);
            if gap > median_h * 0.7 || (indented && gap > -median_h * 0.2) || math_boundary {
                flush(&mut current, &mut paragraphs);
            }
        }
        current.push(line);
    }
    flush(&mut current, &mut paragraphs);
    paragraphs
}

/// Reading order for the fallback path: two-column pages (detected by a
/// gutter no line crosses) read the left column first; otherwise lines are
/// already top-to-bottom.
fn order_for_reading(lines: &[Line]) -> Vec<Line> {
    if lines.len() >= 6 {
        for step in 7..=13 {
            let gutter = step as f64 * 0.05; // 0.35 .. 0.65
            let (left, right): (Vec<&Line>, Vec<&Line>) = lines
                .iter()
                .partition(|l| l.rect.x + l.rect.w / 2.0 < gutter);
            let crosses = lines
                .iter()
                .any(|l| l.rect.x < gutter - 0.02 && l.rect.x + l.rect.w > gutter + 0.02);
            if !crosses && left.len() >= 2 && right.len() >= 2 {
                let mut out: Vec<Line> = left.into_iter().cloned().collect();
                out.extend(right.into_iter().cloned());
                out.sort_by(|a, b| {
                    a.rect
                        .y
                        .partial_cmp(&b.rect.y)
                        .unwrap_or(std::cmp::Ordering::Equal)
                });
                return out;
            }
        }
    }
    lines.to_vec()
}

/// Joins a paragraph's lines: hyphen restoration (plan §3.2 -- hyphen at
/// line end + next line starting lowercase merges without the hyphen),
/// CJK lines join without spaces.
fn join_paragraph_text(lines: &[Line]) -> String {
    let mut text = String::new();
    let mut prev_ends_hyphen = false;
    for (i, line) in lines.iter().enumerate() {
        let next = line.text.trim();
        let starts_lower = next
            .chars()
            .next()
            .map(|c| c.is_ascii_lowercase())
            .unwrap_or(false);
        if i == 0 {
            text.push_str(next);
        } else if prev_ends_hyphen && starts_lower {
            // Hyphen at the previous line's end + lowercase continuation:
            // merge without the hyphen (plan §3.2).
            let head = text.trim_end().trim_end_matches(['-', '‐']).to_string();
            text = head;
            text.push_str(next);
        } else if count_cjk(text.trim_end()) > 0 || count_cjk(next) > 0 {
            text.push_str(next);
        } else {
            text.push(' ');
            text.push_str(next);
        }
        prev_ends_hyphen = line.ends_hyphen;
    }
    normalize_text(&text)
}

/// OCR lines -> paragraphs (plan §3.5): line-level results merged by the
/// same gap rule as the fallback path; confidence is the line minimum.
pub fn ocr_lines_to_paragraphs(lines: &[OcrLine], page: i64) -> Vec<Paragraph> {
    let mut sorted: Vec<&OcrLine> = lines.iter().filter(|l| !l.text.trim().is_empty()).collect();
    sorted.sort_by(|a, b| a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal));
    if sorted.is_empty() {
        return Vec::new();
    }
    let mut heights: Vec<f64> = sorted.iter().map(|l| l.h).collect();
    let median_h = median(&mut heights).unwrap_or(0.02).max(0.005);

    let mut paragraphs: Vec<Paragraph> = Vec::new();
    let mut current: Vec<&OcrLine> = Vec::new();
    let flush = |current: &mut Vec<&OcrLine>, paragraphs: &mut Vec<Paragraph>| {
        if current.is_empty() {
            return;
        }
        let text = join_paragraph_text(
            &current
                .iter()
                .map(|l| Line {
                    text: l.text.clone(),
                    rect: NormRect { x: l.x, y: l.y, w: l.w, h: l.h },
                    ends_hyphen: l.text.trim_end().ends_with('-'),
                })
                .collect::<Vec<_>>(),
        );
        if !text.trim().is_empty() {
            let confidence = current.iter().map(|l| l.confidence).fold(f64::INFINITY, f64::min);
            paragraphs.push(Paragraph {
                text,
                rects: current.iter().map(|l| NormRect { x: l.x, y: l.y, w: l.w, h: l.h }).collect(),
                page,
                kind: ParagraphKind::Text,
                confidence,
                formula_regions: Vec::new(),
            });
        }
        current.clear();
    };
    for line in sorted {
        if let Some(prev) = current.last() {
            let gap = line.y - (prev.y + prev.h);
            if gap > median_h * 0.7 {
                flush(&mut current, &mut paragraphs);
            }
        }
        current.push(line);
    }
    flush(&mut current, &mut paragraphs);
    paragraphs
}

// =============================================================================
// Noise removal (plan §3.3)
// =============================================================================

fn in_margin(rect: &NormRect) -> bool {
    let cy = rect.y + rect.h / 2.0;
    !(MARGIN_FRACTION..=(1.0 - MARGIN_FRACTION)).contains(&cy)
}

fn paragraph_rect(p: &Paragraph) -> Option<NormRect> {
    p.rects.first().copied()
}

/// A paragraph is noise when it sits in the header/footer margin, is short,
/// and either looks like a page number or repeats on an adjacent page.
fn is_noise(text: &str, rect: Option<NormRect>, neighbors: &[String]) -> bool {
    let Some(rect) = rect else {
        return false;
    };
    let norm = normalize_ws(text);
    if norm.is_empty() || norm.chars().count() > MAX_NOISE_CHARS {
        return false;
    }
    if !in_margin(&rect) {
        return false;
    }
    if page_number_like(&norm) {
        return true;
    }
    neighbors
        .iter()
        .any(|n| normalize_ws(n) == norm && !norm.is_empty())
}

/// "12", "iv", "- 3 -", "第 12 页", "Page 12" style strings.
fn page_number_like(s: &str) -> bool {
    let s = s.trim().trim_matches(['-', '—', '–', '·', ' ', '.']);
    if s.is_empty() || s.chars().count() > 16 {
        return false;
    }
    let lower = s.to_ascii_lowercase();
    let body = lower
        .trim_start_matches("page ")
        .trim_start_matches("第 ")
        .trim_start_matches("第")
        .trim_start_matches("page")
        .trim_end_matches(" 页")
        .trim_end_matches('页')
        .trim_end_matches(" page")
        .trim_end_matches("page")
        .trim();
    if body.is_empty() {
        return false;
    }
    let digits = body.chars().all(|c| c.is_ascii_digit());
    let roman = body
        .chars()
        .all(|c| matches!(c, 'i' | 'v' | 'x' | 'l' | 'c' | 'm'));
    digits || roman
}

// =============================================================================
// Formula detection (plan §3.4)
// =============================================================================

/// Page-wide statistics that keep per-char formula signals from firing on
/// the whole page (a font-wide symbolic flag or a global text-matrix scale
/// would otherwise mark everything as math).
#[derive(Debug, Clone, Copy)]
pub struct MathSignals {
    median_ratio: f64,
    symbolic_fraction: f64,
}

fn math_signals(chars: &[PageChar]) -> MathSignals {
    let mut ratios: Vec<f64> = chars
        .iter()
        .filter(|c| !c.ch.trim().is_empty())
        .map(|c| {
            if c.unscaled_size > 0.01 {
                (c.scaled_size / c.unscaled_size).clamp(0.05, 20.0)
            } else {
                1.0
            }
        })
        .collect();
    let median_ratio = median(&mut ratios).unwrap_or(1.0).max(0.05);
    let total = chars.iter().filter(|c| !c.ch.trim().is_empty()).count();
    let symbolic = chars
        .iter()
        .filter(|c| !c.ch.trim().is_empty() && c.is_symbolic)
        .count();
    let symbolic_fraction = if total > 0 {
        symbolic as f64 / total as f64
    } else {
        0.0
    };
    MathSignals {
        median_ratio,
        symbolic_fraction,
    }
}

/// Whether a font name belongs to a math-ONLY family (plan §3.4). Embedded
/// subsets carry a "ABCDEF+Name" prefix, which is stripped first.
///
/// Deliberately narrow: the broad `CM` / `MT` / `TEX` prefixes are NOT used
/// because LaTeX documents set their BODY text in Computer Modern (`CMR10`)
/// and TeX Gyre (`TeXGyrePagella`) -- matching those flagged entire books as
/// formulas (real regression: a LaTeX paper produced zero translated text).
/// Only families that are used exclusively for mathematics are matched, and
/// font metadata is never sufficient on its own (see [text_looks_like_formula]).
fn is_math_font_name(name: &str) -> bool {
    let base = name.split('+').next_back().unwrap_or(name);
    let upper = base.trim().to_ascii_uppercase();
    let prefixes = [
        "CMMI", "CMSY", "CMEX", // Computer Modern math italic / symbols / ext
        "MTMI", "MTSY", "MTEX", // MathType math faces
        "MSAM", "MSBM", "LASY", "EUFM", "EUSM", "RSFS", // AMS / Euler / script
    ];
    if prefixes.iter().any(|p| upper.starts_with(p)) {
        return true;
    }
    [
        "SYMBOL",
        "STIX",
        "XITS",
        "CAMBRIA MATH",
        "LATINMODERNMATH",
        "LATIN MODERN MATH",
        "ASANA MATH",
        "NEO EULER",
        "NEWCM", // New Computer Modern (math companion to TeX Gyre)
        "MATHJAX",
    ]
    .iter()
    .any(|p| upper.contains(p))
}

/// A character whose presence is a reliable, font-independent signal of
/// mathematics: operators, relations, arrows and Greek letters. Ordinary
/// prose is mostly letters, so requiring one of these (plus rejecting real
/// words) separates formulas from sentences.
fn is_strong_math_char(c: char) -> bool {
    matches!(c,
        '+' | '-' | '=' | '<' | '>' | '*' | '/' | '^' | '_' | '|'
        | '±' | '∓' | '×' | '÷' | '⋅' | '∘' | '⊕' | '⊗' | '⊥' | '∝'
        | '∑' | '∏' | '∫' | '∮' | '√' | '∞' | '∂' | '∇'
        | '≤' | '≥' | '≠' | '≈' | '∼' | '≪' | '≫' | '∈' | '∉' | '⊂' | '⊆'
        | '→' | '←' | '↔' | '⇒' | '⇔' | '∀' | '∃' | '⟨' | '⟩'
        | 'α'..='ω' | 'Α'..='Ω'
    )
}

/// Content gate for formula classification (plan §12 known limitation: a font
/// hint alone cannot distinguish prose from math). A run is treated as
/// mathematics only when it contains no ordinary word (a run of >= 3
/// alphabetic chars) AND at least one strong math operator/symbol.
///
/// This is what keeps a LaTeX paper's body text -- set in the same
/// Computer-Modern-derived families as its equations -- from being classified
/// as formulas and skipped by translation.
pub fn text_looks_like_formula(text: &str) -> bool {
    let mut strong = 0usize;
    let mut run = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            run += 1;
            // A real word: prose, never a formula (covers CJK too, where each
            // ideograph is alphabetic).
            if run >= 3 {
                return false;
            }
        } else {
            run = 0;
            if is_strong_math_char(c) {
                strong += 1;
            }
        }
    }
    strong >= 1
}

fn is_math_char(c: &PageChar, s: &MathSignals) -> bool {
    // A literal operator/symbol is math regardless of the font.
    if is_strong_math_char(c.ch.chars().next().unwrap_or(' ')) {
        return true;
    }
    if is_math_font_name(&c.font_name) {
        return true;
    }
    if c.is_symbolic && s.symbolic_fraction < 0.5 {
        return true;
    }
    if c.unscaled_size > 0.01 {
        let ratio = (c.scaled_size / c.unscaled_size).clamp(0.05, 20.0);
        // Sub/superscript: scale deviates from the page median by >18%.
        if ratio < s.median_ratio * 0.82 || ratio > s.median_ratio * 1.22 {
            return true;
        }
    }
    if c.angle.abs() > 1.0 {
        return true;
    }
    false
}

/// Groups consecutive math chars (single spaces allowed inside a run) into
/// regions; each region needs >= 2 non-space chars to avoid flagging stray
/// glyphs. Returns (rect, text) per region, in content order.
fn detect_formula_regions(chars: &[PageChar], signals: &MathSignals) -> Vec<(NormRect, String)> {
    let mut regions = Vec::new();
    let mut run: Vec<&PageChar> = Vec::new();

    let flush = |run: &mut Vec<&PageChar>, regions: &mut Vec<(NormRect, String)>| {
        let non_space: Vec<&&PageChar> = run.iter().filter(|c| !c.ch.trim().is_empty()).collect();
        if non_space.len() >= 2 {
            let text: String = run.iter().map(|c| c.ch.as_str()).collect::<Vec<_>>().join("");
            let text = normalize_ws(&text);
            // Content gate: a run of ordinary words sharing a math-font name
            // (e.g. a LaTeX paper's body text) is NOT a formula. This is the
            // protection that keeps prose from being turned into placeholders.
            if text_looks_like_formula(&text) {
                let x0 = run.iter().map(|c| c.x).fold(f64::MAX, f64::min);
                let y0 = run.iter().map(|c| c.y).fold(f64::MAX, f64::min);
                let x1 = run.iter().map(|c| c.x + c.w).fold(0.0, f64::max);
                let y1 = run.iter().map(|c| c.y + c.h).fold(0.0, f64::max);
                regions.push((
                    NormRect {
                        x: x0,
                        y: y0,
                        w: (x1 - x0).max(0.0),
                        h: (y1 - y0).max(0.0),
                    },
                    text,
                ));
            }
        }
        run.clear();
    };

    for c in chars {
        if c.ch.trim().is_empty() {
            // A single space inside a run is kept (x + y stays one region);
            // the flush below drops trailing spaces from closed runs.
            if !run.is_empty() {
                run.push(c);
            }
            continue;
        }
        if is_math_char(c, signals) {
            run.push(c);
        } else {
            flush(&mut run, &mut regions);
        }
    }
    flush(&mut run, &mut regions);
    regions
}

/// Attaches formula regions to paragraphs and marks whole-paragraph
/// formulas (see [is_whole_paragraph_formula] for the classification).
fn attach_formulas(
    mut paragraphs: Vec<Paragraph>,
    chars: &[PageChar],
    signals: &MathSignals,
    regions: &[(NormRect, String)],
) -> Vec<Paragraph> {
    // Page-wide line-width reference for the "centered short block" signal:
    // display equations are narrow relative to the column's full lines.
    let mut line_ws: Vec<f64> = paragraphs
        .iter()
        .flat_map(|p| p.rects.iter().map(|r| r.w))
        .filter(|w| *w > 0.0)
        .collect();
    line_ws.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let wide_p95 = line_ws
        .get(line_ws.len().saturating_sub(1).min(line_ws.len() * 95 / 100))
        .copied()
        .unwrap_or(1.0);

    for p in &mut paragraphs {
        let Some(rect) = paragraph_rect(p) else {
            continue;
        };
        let mut inside = 0usize;
        let mut math_inside = 0usize;
        let mut alpha_inside = 0usize;
        let mut math_alpha_inside = 0usize;
        for c in chars {
            if c.ch.trim().is_empty() {
                continue;
            }
            let cx = c.x + c.w / 2.0;
            let cy = c.y + c.h / 2.0;
            let contains = cx >= rect.x
                && cx <= rect.x + rect.w
                && cy >= rect.y
                && cy <= rect.y + rect.h;
            if contains {
                inside += 1;
                let math = is_math_char(c, signals);
                if math {
                    math_inside += 1;
                }
                if c.ch.chars().next().is_some_and(|ch| ch.is_alphabetic()) {
                    alpha_inside += 1;
                    if math {
                        math_alpha_inside += 1;
                    }
                }
            }
        }
        let math_ratio = if inside > 0 {
            math_inside as f64 / inside as f64
        } else {
            0.0
        };
        let math_alpha_ratio = if alpha_inside > 0 {
            math_alpha_inside as f64 / alpha_inside as f64
        } else {
            0.0
        };
        if is_whole_paragraph_formula(p, math_ratio, math_alpha_ratio, wide_p95) {
            p.kind = ParagraphKind::Formula;
            // Whole-formula paragraphs keep their regions for token mapping.
            p.formula_regions = regions
                .iter()
                .filter(|(r, _)| rects_overlap(r, &rect))
                .map(|(r, t)| FormulaRegion {
                    rect: *r,
                    image_path: None,
                    source_text: t.clone(),
                    placeholder: String::new(),
                })
                .collect();
            continue;
        }
        if p.kind == ParagraphKind::Text {
            p.formula_regions = regions
                .iter()
                .filter(|(r, _)| rects_overlap(r, &rect))
                .map(|(r, t)| FormulaRegion {
                    rect: *r,
                    image_path: None,
                    source_text: t.clone(),
                    placeholder: String::new(),
                })
                .collect();
        }
    }
    paragraphs
}

/// Runs of at least [min_len] alphabetic characters in [text].
fn count_alpha_runs(text: &str, min_len: usize) -> usize {
    let mut runs = 0usize;
    let mut cur = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            cur += 1;
        } else {
            if cur >= min_len {
                runs += 1;
            }
            cur = 0;
        }
    }
    if cur >= min_len {
        runs += 1;
    }
    runs
}

/// Whether a paragraph is a DISPLAY FORMULA and must keep its original
/// pixels (never whitened, never machine-translated). Three signals, any of
/// which classifies it as math:
///
/// 1. classic: >= 80% of its chars are math signals AND the text has no
///    ordinary word (pure symbol equations like "E = mc2");
/// 2. math letters: >= 60% of its ALPHABETIC chars are set in math fonts or
///    sub/superscript-scaled, and the raw text has at most one long word --
///    catches "Γ ⊢ t : T_effect" where the subscript word "effect" would
///    otherwise read as prose;
/// 3. centered short block with math content: display equations sit on
///    narrow, horizontally centered lines (vs the column's full-width prose
///    lines) -- catches multi-line case environments whose condition words
///    ("activating if σ ⊬ d ...") are set in the text font.
///
/// The long-word guard in rule 1 and the width of rule 3 are what keep a
/// LaTeX paper's BODY text -- often set in Computer-Modern-derived families
/// -- classified as prose (the original regression).
fn is_whole_paragraph_formula(
    p: &Paragraph,
    math_ratio: f64,
    math_alpha_ratio: f64,
    wide_p95: f64,
) -> bool {
    // Paragraphs with no measurable chars cannot be math (the ratio callers
    // pass 0.0 for them, so only rule 3 could fire; require a non-empty rect).
    if p.text.trim().is_empty() || p.rects.is_empty() {
        return false;
    }
    // Rule 1: pure symbol equations.
    if math_ratio >= 0.8 && text_looks_like_formula(&p.text) {
        return true;
    }
    // Rule 2: math-font letters dominate the paragraph's alphabet.
    if math_alpha_ratio >= 0.6 && count_alpha_runs(&p.text, 4) <= 1 {
        return true;
    }
    // Rule 3: centered short block carrying math content. A trailing
    // equation number "(2)" widens the line rightward, so such lines get a
    // looser center tolerance.
    let (union, max_line_w) = union_and_max_line(p);
    let cx = union.x + union.w / 2.0;
    let tol = if ends_with_eq_number(&p.text) { 0.16 } else { 0.06 };
    let centered_short = max_line_w <= wide_p95 * 0.7
        && [0.25, 0.5, 0.75]
            .iter()
            .any(|c| (cx - c).abs() <= tol);
    if centered_short && (math_ratio >= 0.12 || text_looks_like_formula(&p.text)) {
        return true;
    }
    false
}

/// Whether [text] ends with an equation-number marker like "(2)".
fn ends_with_eq_number(text: &str) -> bool {
    let t = text.trim_end();
    if !t.ends_with(')') {
        return false;
    }
    let Some(open) = t.rfind('(') else {
        return false;
    };
    let inner = &t[open + 1..t.len() - 1];
    !inner.is_empty() && inner.chars().all(|c| c.is_ascii_digit())
}

/// Union of the paragraph's line rects plus its widest line.
fn union_and_max_line(p: &Paragraph) -> (NormRect, f64) {
    let mut x0 = f64::MAX;
    let mut y0 = f64::MAX;
    let mut x1 = 0.0f64;
    let mut y1 = 0.0f64;
    let mut max_w = 0.0f64;
    for r in &p.rects {
        x0 = x0.min(r.x);
        y0 = y0.min(r.y);
        x1 = x1.max(r.x + r.w);
        y1 = y1.max(r.y + r.h);
        max_w = max_w.max(r.w);
    }
    if p.rects.is_empty() {
        return (
            NormRect {
                x: 0.0,
                y: 0.0,
                w: 0.0,
                h: 0.0,
            },
            0.0,
        );
    }
    (
        NormRect {
            x: x0,
            y: y0,
            w: (x1 - x0).max(0.0),
            h: (y1 - y0).max(0.0),
        },
        max_w,
    )
}

fn rects_overlap(a: &NormRect, b: &NormRect) -> bool {
    a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

// =============================================================================
// Text utilities
// =============================================================================

/// Ligature normalization (plan §3.2) + whitespace collapse.
pub fn normalize_text(s: &str) -> String {
    let s = s
        .replace('\u{FB00}', "ff")
        .replace('\u{FB01}', "fi")
        .replace('\u{FB02}', "fl")
        .replace('\u{FB03}', "ffi")
        .replace('\u{FB04}', "ffl")
        .replace(['\u{FB05}', '\u{FB06}'], "st")
        .replace('\u{00AD}', ""); // soft hyphen
    normalize_ws(&s)
}

fn normalize_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn count_cjk(s: &str) -> usize {
    s.chars()
        .filter(|c| {
            matches!(c,
                '\u{4E00}'..='\u{9FFF}'      // CJK unified
                | '\u{3400}'..='\u{4DBF}'    // ext A
                | '\u{F900}'..='\u{FAFF}'    // compat
                | '\u{3000}'..='\u{303F}'    // CJK punctuation
                | '\u{FF00}'..='\u{FFEF}')   // fullwidth forms
        })
        .count()
}

/// CJK fraction of a text (drives source-language detection, plan §4.5).
pub fn cjk_ratio(s: &str) -> f64 {
    let total = s.chars().filter(|c| !c.is_whitespace()).count();
    if total == 0 {
        0.0
    } else {
        count_cjk(s) as f64 / total as f64
    }
}

pub(crate) fn median(values: &mut [f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = values.len() / 2;
    Some(if values.len() % 2 == 1 {
        values[mid]
    } else {
        (values[mid - 1] + values[mid]) / 2.0
    })
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn line(text: &str, x: f64, y: f64, w: f64, h: f64) -> Line {
        Line {
            text: text.into(),
            rect: NormRect { x, y, w, h },
            ends_hyphen: text.trim_end().ends_with('-'),
        }
    }

    #[test]
    fn page_number_like_matches_common_patterns() {
        for s in [
            "12", " 12 ", "- 3 -", "iv", "VI", "第 12 页", "第12页", "Page 12",
            "page 7", "· 8 ·",
        ] {
            assert!(page_number_like(s), "{s:?} should be a page number");
        }
        for s in [
            "Introduction to Quantum Mechanics",
            "12 ways to die",
            "pagina",
            "",
            "Chapter IV — A Long Chapter Title",
        ] {
            assert!(!page_number_like(s), "{s:?} should not be a page number");
        }
    }

    #[test]
    fn hyphen_and_cjk_join_rules() {
        // Hyphen + lowercase continuation -> merge without the hyphen.
        let joined = join_paragraph_text(&[line("continua-", 0.1, 0.1, 0.7, 0.02), line("tion follows", 0.1, 0.13, 0.6, 0.02)]);
        assert_eq!(joined, "continuation follows");

        // Hyphen + uppercase -> keep the hyphen, join with space.
        let joined = join_paragraph_text(&[line("state-of-", 0.1, 0.1, 0.5, 0.02), line("The-art", 0.1, 0.13, 0.5, 0.02)]);
        assert_eq!(joined, "state-of- The-art");

        // CJK lines join without spaces.
        let joined = join_paragraph_text(&[line("量子力学", 0.1, 0.1, 0.5, 0.02), line("是物理学的分支", 0.1, 0.13, 0.7, 0.02)]);
        assert_eq!(joined, "量子力学是物理学的分支");

        // Ligatures normalized.
        assert_eq!(normalize_text("ﬁle ﬂow"), "file flow");
    }

    #[test]
    fn ocr_lines_merge_by_gap_with_min_confidence() {
        let lines = vec![
            OcrLine { text: "第一段第一行".into(), x: 0.1, y: 0.10, w: 0.6, h: 0.02, confidence: 0.95 },
            OcrLine { text: "第一段第二行".into(), x: 0.1, y: 0.13, w: 0.6, h: 0.02, confidence: 0.75 },
            // Big vertical gap -> new paragraph.
            OcrLine { text: "第二段".into(), x: 0.1, y: 0.30, w: 0.5, h: 0.02, confidence: 0.99 },
        ];
        let paras = ocr_lines_to_paragraphs(&lines, 5);
        assert_eq!(paras.len(), 2);
        assert_eq!(paras[0].text, "第一段第一行第一段第二行");
        // Confidence is the minimum of the merged lines.
        assert!((paras[0].confidence - 0.75).abs() < 1e-9);
        assert_eq!(paras[0].page, 5);
        assert!((paras[1].confidence - 0.99).abs() < 1e-9);
    }

    #[test]
    fn math_font_name_detection() {
        // Math-ONLY families are matched.
        for name in [
            "CMMI12", "CMSY10", "CMEX10", "MTMI", "MTSY", "Symbol", "StandardSymbolsPS",
            "STIXGeneral", "XITSMath", "Cambria Math", "ABCDEF+CMMI12", "MSAM10",
            "NewCMMath-Book", "LatinModernMath",
        ] {
            assert!(is_math_font_name(name), "{name}");
        }
        // Body-text families are NOT (regression: LaTeX body fonts used to be
        // matched via the broad CM/TEX prefixes, flagging whole books as math).
        for name in [
            "Helvetica",
            "TimesNewRoman",
            "SimSun",
            "NotoSansSC",
            "ArialMT",
            "CMR10",              // Computer Modern Roman = body serif
            "TeXGyrePagella-Regular",
            "DejaVuSansMono",
        ] {
            assert!(!is_math_font_name(name), "{name}");
        }
    }

    #[test]
    fn content_gate_separates_prose_from_formulas() {
        // Prose (real words) is never a formula, whatever the font.
        for text in [
            "Contents 1. Introduction . . . . . . . . . . . . . . . . . . . .",
            "1.2.3. The Coarse-Grained Workaround",
            "Quantum mechanics is strange.",
            "量子力学是物理学的分支",
            "state-of-the-art systems",
        ] {
            assert!(!text_looks_like_formula(text), "{text:?}");
        }
        // Real formulas (operators/symbols, no ordinary words) pass.
        for text in ["x2 +y", "E=mc2", "a ≤ b", "α + β", "∑ x", "f(x)=0"] {
            assert!(text_looks_like_formula(text), "{text:?}");
        }
    }

    fn char(ch: &str, x: f64, y: f64, w: f64, h: f64, font: &str) -> PageChar {
        PageChar {
            ch: ch.into(),
            x,
            y,
            w,
            h,
            font_name: font.into(),
            is_symbolic: false,
            scaled_size: 12.0,
            unscaled_size: 12.0,
            angle: 0.0,
            is_hyphen: false,
        }
    }

    /// Regression: a body paragraph set in a math-named font (LaTeX body uses
    /// Computer-Modern-derived faces) must stay `Text`, not `Formula`.
    #[test]
    fn latex_body_in_math_font_is_not_a_formula() {
        let mut chars = Vec::new();
        // "Introduction to systems" -- every char in NewCMMath, a math font.
        for (i, c) in "Introduction to systems".chars().enumerate() {
            chars.push(char(
                &c.to_string(),
                0.1 + i as f64 * 0.012,
                0.3,
                0.01,
                0.02,
                "NewCMMath-Book",
            ));
        }
        let paras = vec![Paragraph {
            text: "Introduction to systems".into(),
            rects: vec![NormRect { x: 0.08, y: 0.29, w: 0.8, h: 0.04 }],
            page: 1,
            kind: ParagraphKind::Text,
            confidence: 1.0,
            formula_regions: Vec::new(),
        }];
        let signals = math_signals(&chars);
        let regions = detect_formula_regions(&chars, &signals);
        let out = attach_formulas(paras, &chars, &signals, &regions);
        assert_eq!(out[0].kind, ParagraphKind::Text,
            "prose in a math font must not become Formula");
        assert!(out[0].formula_regions.is_empty(),
            "prose must not produce formula regions: {:?}", out[0].formula_regions);
    }

    /// Display equation with a subscript WORD ("Γ ⊢ t : T_effect"): the
    /// subscript reads as prose in the raw text, but its letters are math
    /// fonts -> rule 2 classifies the paragraph as a display formula so the
    /// overlay keeps the original pixels.
    #[test]
    fn display_equation_with_subscript_word_is_formula() {
        let mut chars = Vec::new();
        // A full-width prose sibling anchors the page's wide-line reference.
        for (i, c) in "Ordinary prose fills the whole column here".chars().enumerate() {
            chars.push(char(&c.to_string(), 0.1 + i as f64 * 0.012, 0.1, 0.01, 0.02, "Helvetica"));
        }
        // The equation: centered, narrow, math fonts; "effect" subscript is
        // CMMI at 0.7 scale.
        let eq = "Γ ⊢ t : T";
        for (i, c) in eq.chars().enumerate() {
            chars.push(char(&c.to_string(), 0.42 + i as f64 * 0.012, 0.3, 0.01, 0.02, "CMMI10"));
        }
        for (i, c) in "effect".chars().enumerate() {
            let mut ch = char(&c.to_string(), 0.54 + i as f64 * 0.007, 0.315, 0.007, 0.014, "CMMI10");
            ch.scaled_size = 8.4;
            ch.unscaled_size = 12.0;
            chars.push(ch);
        }
        let paras = vec![
            Paragraph {
                text: "Ordinary prose fills the whole column here".into(),
                rects: vec![NormRect { x: 0.09, y: 0.09, w: 0.62, h: 0.022 }],
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
            Paragraph {
                text: "Γ ⊢ t : Teffect".into(),
                rects: vec![NormRect { x: 0.41, y: 0.29, w: 0.2, h: 0.03 }],
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
        ];
        let signals = math_signals(&chars);
        let regions = detect_formula_regions(&chars, &signals);
        let out = attach_formulas(paras, &chars, &signals, &regions);
        assert_eq!(out[1].kind, ParagraphKind::Formula, "display eq must be kept: {:?}", out[1].text);
        assert_eq!(out[0].kind, ParagraphKind::Text);
    }

    /// A centered multi-line case environment whose condition words are set
    /// in the TEXT font ("activating if σ ⊬ d ...") is still a display
    /// formula (rule 3: centered short block with some math content).
    #[test]
    fn centered_cases_block_with_words_is_formula() {
        let mut chars = Vec::new();
        for (i, c) in "Ordinary prose fills the whole column here".chars().enumerate() {
            chars.push(char(&c.to_string(), 0.1 + i as f64 * 0.012, 0.1, 0.01, 0.02, "Helvetica"));
        }
        // Three centered lines; words in Times, symbols in CMSY10.
        let lines = [
            "notify(σ, σ′) := activating if σ",
            "deactivating if σ ⊢ d",
            "neutral otherwise",
        ];
        for (li, line) in lines.iter().enumerate() {
            let y = 0.3 + li as f64 * 0.03;
            let mut x = 0.36;
            for c in line.chars() {
                let font = if matches!(c, 'σ' | 'σ' | '′' | '⊢' | '¬' | '∧' | '(' | ')' | ',' | ':' | '=') {
                    "CMSY10"
                } else {
                    "Times"
                };
                chars.push(char(&c.to_string(), x, y, 0.01, 0.02, font));
                x += 0.012;
            }
        }
        let paras = vec![
            Paragraph {
                text: "Ordinary prose fills the whole column here".into(),
                rects: vec![NormRect { x: 0.09, y: 0.09, w: 0.62, h: 0.022 }],
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
            Paragraph {
                text: lines.join(" ").as_str().into(),
                rects: lines.iter().enumerate().map(|(li, _)| NormRect {
                    x: 0.35, y: 0.29 + li as f64 * 0.03, w: 0.24, h: 0.022,
                }).collect(),
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
        ];
        let signals = math_signals(&chars);
        let regions = detect_formula_regions(&chars, &signals);
        let out = attach_formulas(paras, &chars, &signals, &regions);
        assert_eq!(out[1].kind, ParagraphKind::Formula, "cases block must be kept: {:?}", out[1].text);
        assert_eq!(out[0].kind, ParagraphKind::Text);
    }

    /// A left-aligned short heading is NOT a display formula even though it
    /// is narrower than the column (rule 3 requires a centered line).
    #[test]
    fn left_aligned_short_heading_stays_text() {
        let mut chars = Vec::new();
        for (i, c) in "Ordinary prose fills the whole column here".chars().enumerate() {
            chars.push(char(&c.to_string(), 0.1 + i as f64 * 0.012, 0.1, 0.01, 0.02, "Helvetica"));
        }
        for (i, c) in "2.1. Effects".chars().enumerate() {
            chars.push(char(&c.to_string(), 0.1 + i as f64 * 0.012, 0.3, 0.01, 0.02, "Helvetica"));
        }
        let paras = vec![
            Paragraph {
                text: "Ordinary prose fills the whole column here".into(),
                rects: vec![NormRect { x: 0.09, y: 0.09, w: 0.62, h: 0.022 }],
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
            Paragraph {
                text: "2.1. Effects".into(),
                rects: vec![NormRect { x: 0.09, y: 0.29, w: 0.15, h: 0.022 }],
                page: 1,
                kind: ParagraphKind::Text,
                confidence: 1.0,
                formula_regions: Vec::new(),
            },
        ];
        let signals = math_signals(&chars);
        let regions = detect_formula_regions(&chars, &signals);
        let out = attach_formulas(paras, &chars, &signals, &regions);
        assert_eq!(out[1].kind, ParagraphKind::Text);
    }

    #[test]
    fn formula_runs_group_consecutive_math_chars() {
        let chars = vec![
            char("x", 0.10, 0.5, 0.01, 0.01, "CMMI12"),
            char("2", 0.11, 0.49, 0.01, 0.01, "CMSY10"),
            char(" ", 0.12, 0.5, 0.005, 0.01, "Helvetica"),
            char("+", 0.13, 0.5, 0.01, 0.01, "CMSY10"),
            char("y", 0.14, 0.5, 0.01, 0.01, "CMMI12"),
            char("i", 0.16, 0.5, 0.01, 0.01, "Helvetica"), // breaks the run
            char("s", 0.17, 0.5, 0.01, 0.01, "Helvetica"),
        ];
        let signals = math_signals(&chars);
        let regions = detect_formula_regions(&chars, &signals);
        assert_eq!(regions.len(), 1, "{regions:?}");
        // Region text is the chars in content order -- exactly the substring
        // the paragraph text contains (placeholder substitution relies on it).
        assert_eq!(regions[0].1, "x2 +y");
    }

    #[test]
    fn superscript_scaling_flags_math() {
        // Median ratio is 1.0; a char scaled to 0.7 is a superscript.
        let mut chars = Vec::new();
        for (i, c) in ["a", "b", "c", "d"].iter().enumerate() {
            chars.push(char(c, 0.1 + i as f64 * 0.02, 0.5, 0.01, 0.01, "Times"));
        }
        let mut sup = char("2", 0.2, 0.48, 0.008, 0.008, "Times");
        sup.scaled_size = 8.4; // 0.7 * unscaled
        sup.unscaled_size = 12.0;
        chars.push(sup.clone());
        let signals = math_signals(&chars);
        assert!((signals.median_ratio - 1.0).abs() < 1e-6);
        assert!(!is_math_char(&chars[0], &signals));
        assert!(is_math_char(&sup, &signals));
    }

    #[test]
    fn symbolic_flag_ignored_when_font_wide() {
        let chars: Vec<PageChar> = (0..10)
            .map(|i| {
                let mut c = char("字", 0.1 + i as f64 * 0.02, 0.5, 0.01, 0.01, "SomeFont");
                c.is_symbolic = true;
                c
            })
            .collect();
        let signals = math_signals(&chars);
        assert!((signals.symbolic_fraction - 1.0).abs() < 1e-9);
        assert!(!is_math_char(&chars[0], &signals));
    }

    #[test]
    fn noise_filter_removes_headers_and_page_numbers() {
        let header = "Chapter 3 · Introduction";
        let pageno = "- 42 -";
        assert!(is_noise(header, Some(NormRect { x: 0.3, y: 0.03, w: 0.4, h: 0.02 }), &["Chapter 3 · Introduction".into()]));
        assert!(is_noise(pageno, Some(NormRect { x: 0.45, y: 0.96, w: 0.1, h: 0.02 }), &[]));
        // Same text outside the margin is content.
        assert!(!is_noise(header, Some(NormRect { x: 0.3, y: 0.3, w: 0.4, h: 0.02 }), &[]));
        // Margin text that is neither a page number nor repeated stays.
        assert!(!is_noise("Some unique footnote-ish line", Some(NormRect { x: 0.2, y: 0.97, w: 0.6, h: 0.02 }), &[]));
    }

    #[test]
    fn cjk_ratio_detection() {
        assert!(cjk_ratio("量子力学是物理学分支") > 0.9);
        assert!(cjk_ratio("The quick brown fox") < 0.05);
        assert!((cjk_ratio("这 is mixed 文本")).abs() > 0.0);
    }

    /// End-to-end: build a synthetic PDF (header + two paragraphs + page
    /// number), save it, reopen it through an independent handle and extract
    /// -- the header/page number drop as noise, the paragraphs survive with
    /// correct text. Skips when libpdfium is not reachable (run tests from
    /// the repo root so `rust/libpdfium/` is on the search path).
    #[test]
    fn extract_page_end_to_end_from_synthetic_pdf() {
        let tmp = std::env::temp_dir().join(format!("rbwa_extract_test_{}.pdf", std::process::id()));
        // Build + reopen the fixture under the pdfium lock (pdfium is not
        // thread-safe, and other tests use it concurrently).
        let built = crate::pdf::with_pdfium_lock(|pdfium| {
            let mut doc = pdfium.create_new_pdf()?;
            {
                let font = doc.fonts_mut().helvetica();
                let mut page = doc
                    .pages_mut()
                    .create_page_at_end(PdfPagePaperSize::a4())?;
                let objects = page.objects_mut();
                let mk =
                    |objects: &mut PdfPageObjects<'_>, x: f32, y: f32, text: &str, size: f32| {
                        objects
                            .create_text_object(
                                PdfPoints::new(x),
                                PdfPoints::new(y),
                                text,
                                font,
                                PdfPoints::new(size),
                            )
                            .map(|_| ())
                    };
                // A4: 595 x 842 pt. Row order top-to-bottom.
                mk(objects, 200.0, 800.0, "Chapter 3 Introduction", 10.0)?; // header
                mk(objects, 50.0, 700.0, "First paragraph line one", 12.0)?;
                mk(objects, 50.0, 685.0, "and its second line", 12.0)?;
                mk(objects, 50.0, 600.0, "Second paragraph stands alone", 12.0)?;
                mk(objects, 280.0, 50.0, "- 42 -", 10.0)?; // page number
            }
            doc.save_to_file(&tmp)?;
            Ok(())
        });
        if built.is_err() {
            eprintln!("skipping: libpdfium not on the search path");
            return;
        }

        // The header repeats on the adjacent page, so pass it as a neighbor
        // (the real pipeline supplies neighbor margin texts, plan §3.3).
        let neighbors = vec!["Chapter 3 Introduction".to_string()];
        let outcome = crate::pdf::with_document_file(tmp.to_str().unwrap(), |doc2| {
            extract_page(doc2, 1, &neighbors)
        })
        .unwrap();
        assert!(outcome.has_text_layer);
        let texts: Vec<String> = outcome
            .paragraphs
            .iter()
            .map(|p| p.text.clone())
            .collect();
        assert_eq!(
            texts,
            vec![
                "First paragraph line one and its second line".to_string(),
                "Second paragraph stands alone".to_string(),
            ],
            "header + page number must be dropped as noise: {texts:?}"
        );
        assert_eq!(outcome.paragraphs[0].page, 1);
        let _ = std::fs::remove_file(&tmp);
    }
}
