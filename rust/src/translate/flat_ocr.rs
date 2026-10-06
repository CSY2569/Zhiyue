//! Flat OCR bridge: PDF text layer / local OCR -> `generic_flat_ocr` JSON.
//!
//! The RetainPDF pipeline ([`crate::translate::job`]) consumes a canonical
//! `document.v1.json`, produced by its `normalize-ocr` stage from a provider
//! payload. This module builds the simplest such payload: a flat list of text
//! blocks per page (`{"provider":"generic_flat_ocr","pages":[...]}`), which
//! their adapter converts, validates and rescales to PDF point space.
//!
//! Two sources feed the same block pipeline:
//!   * text-layer PDFs -- pdfium per-char geometry with font metadata, then
//!     line clustering / paragraph merging / reading order / noise removal
//!     (ported from the retired built-in pipeline's `extract.rs`, tag
//!     `pre-babeldoc-replacement`);
//!   * scanned pages (no text layer) -- the local PP-OCRv4 engine (or its
//!     `page_ocr_cache` rows), merged with the same paragraph rules.
//!
//! Output block fields:
//!   * `type`: `text` | `formula` (whole-paragraph display formulas keep their
//!     original page pixels; the adapter locks them as no-translate);
//!   * `sub_type`: what the adapter's policy/layout mapping understands --
//!     `heading` / `body` / `abstract` / `caption` / `footnote` / `header` /
//!     `footer`. NOTE: we never emit `title`: the flat adapter locks titles as
//!     no-translate (unlike their own Paddle adapter, which translates them),
//!     so title-like lines are emitted as `heading` to be translated with a
//!     heading layout role;
//!   * `bbox`: PDF points, top-left origin (their normalizer rescales against
//!     the source PDF page rect).

use serde::Serialize;

use crate::error::{AppError, AppResult};
use crate::models::annotation::NormRect;
use crate::ocr::OcrLine;

const MARGIN_FRACTION: f64 = 0.08;
/// A margin line longer than this is treated as content, not noise.
const MAX_NOISE_CHARS: usize = 80;
/// Local OCR renders scanned pages at this scale (72 dpi x scale).
const OCR_RENDER_SCALE: f32 = 2.0;
/// OCR model set for whole-book translation (quality over speed; one-off run).
const OCR_MODE: &str = "high_precision";

// =============================================================================
// Output model (serialized to the provider payload)
// =============================================================================

/// One flat text block, in PDF points (top-left origin).
#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct FlatBlock {
    #[serde(rename = "type")]
    pub kind: String,
    pub sub_type: String,
    pub bbox: [f64; 4],
    pub text: String,
}

/// One page of the provider payload.
#[derive(Debug, Clone, Serialize)]
pub struct FlatPage {
    pub page: i64,
    pub width: f64,
    pub height: f64,
    pub unit: &'static str,
    pub blocks: Vec<FlatBlock>,
}

/// The complete `generic_flat_ocr` payload.
#[derive(Debug, Clone, Serialize)]
pub struct FlatDocument {
    pub provider: &'static str,
    pub pages: Vec<FlatPage>,
}

impl FlatDocument {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_default()
    }
}

// =============================================================================
// Block pipeline (ported from the retired built-in pipeline's extract.rs)
// =============================================================================

/// A page character with geometry + font metadata for formula detection.
/// Box is normalized [0,1], top-left origin.
#[derive(Debug, Clone)]
struct PageChar {
    ch: String,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    font_name: String,
    is_symbolic: bool,
    scaled_size: f64,
    unscaled_size: f64,
    angle: f64,
    is_hyphen: bool,
}

/// One clustered text line.
#[derive(Debug, Clone)]
struct Line {
    text: String,
    rect: NormRect,
    ends_hyphen: bool,
}

/// One reconstructed paragraph of a page (before sub_type classification).
#[derive(Debug, Clone)]
struct Para {
    text: String,
    rects: Vec<NormRect>,
    /// Max char height for text-layer paragraphs, max line height for OCR
    /// (the sub_type heuristics' size proxy).
    size: f64,
}

fn collect_page_chars(doc: &pdfium_render::prelude::PdfDocument<'_>, page: i64) -> AppResult<Vec<PageChar>> {
    use pdfium_render::prelude::*;
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

/// Margin-band line texts of a page, for cross-page noise comparison.
fn margin_line_texts(chars: &[PageChar]) -> Vec<String> {
    cluster_lines(chars)
        .into_iter()
        .filter(|l| in_margin(&l.rect))
        .map(|l| normalize_ws(&l.text))
        .collect()
}

/// Groups chars into lines by baseline proximity. Chars arrive in content
/// order; each lands on the existing line whose center y is within half a
/// line height, else starts a new line. Lines are then sorted top-to-bottom
/// and their chars left-to-right.
fn cluster_lines(chars: &[PageChar]) -> Vec<Line> {
    let mut groups: Vec<(Vec<usize>, f64, f64)> = Vec::new();
    for (i, c) in chars.iter().enumerate() {
        if c.ch == "\r" || c.ch == "\n" || c.ch == "\u{0}" {
            continue;
        }
        let cy = c.y + c.h / 2.0;
        if c.ch.trim().is_empty() {
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
                    if text.is_empty() {
                        continue;
                    }
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

/// 95th-percentile line width -- the "wide line" reference display equations
/// (narrow, centered) are compared against.
fn p95_width(mut widths: Vec<f64>) -> f64 {
    widths.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    widths
        .get(widths.len().saturating_sub(1).min(widths.len() * 95 / 100))
        .copied()
        .unwrap_or(1.0)
}

/// Whether a line/block of width [w] centered at [cx] is a narrow,
/// horizontally centered display construct.
fn is_centered_short(w: f64, cx: f64, wide_p95: f64, tol: f64) -> bool {
    w <= wide_p95 * 0.7 && [0.25, 0.5, 0.75].iter().any(|c| (cx - c).abs() <= tol)
}

/// Merges clustered lines into paragraphs: gap + first-line-indent rules,
/// two-column split, display-math boundary splitting.
fn fallback_paragraphs(chars: &[PageChar]) -> Vec<Para> {
    let lines = cluster_lines(chars);
    if lines.is_empty() {
        return Vec::new();
    }
    let ordered = order_for_reading(&lines);
    let mut heights: Vec<f64> = ordered.iter().map(|l| l.rect.h).collect();
    let median_h = median(&mut heights).unwrap_or(0.02).max(0.005);

    let wide_p95 = p95_width(ordered.iter().map(|l| l.rect.w).filter(|w| *w > 0.0).collect());
    // A "display-math flag" requires BOTH the narrow/centered geometry AND
    // math-shaped text: a short last line of a prose paragraph is often
    // narrow and its center can sit near a column center, and splitting
    // prose fragments paragraphs (real regression in the smoke fixture).
    let display_flag = |l: &Line| -> (bool, f64) {
        let cx = l.rect.x + l.rect.w / 2.0;
        (
            is_centered_short(l.rect.w, cx, wide_p95, 0.06) && text_looks_like_formula(&l.text),
            cx,
        )
    };

    let mut paragraphs: Vec<Para> = Vec::new();
    let mut current: Vec<Line> = Vec::new();
    let flush = |current: &mut Vec<Line>, paragraphs: &mut Vec<Para>| {
        if current.is_empty() {
            return;
        }
        let text = join_paragraph_text(current);
        if !text.trim().is_empty() {
            // Provisional size from line heights; the text-layer path
            // replaces it with a real font-size measurement afterwards.
            let size = current.iter().map(|l| l.rect.h).fold(0.0f64, f64::max);
            paragraphs.push(Para {
                text,
                rects: current.iter().map(|l| l.rect).collect(),
                size,
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
            let math_boundary =
                narrow != prev_narrow || (narrow && (cx - prev_cx).abs() > 0.05);
            if gap > median_h * 0.7 || (indented && gap > -median_h * 0.2) || math_boundary {
                flush(&mut current, &mut paragraphs);
            }
        }
        current.push(line);
    }
    flush(&mut current, &mut paragraphs);
    paragraphs
}

/// Reading order: two-column pages (detected by a gutter no line crosses)
/// read the left column first; otherwise lines are already top-to-bottom.
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

/// Joins a paragraph's lines: hyphen restoration (hyphen at line end + next
/// line starting lowercase merges without the hyphen), CJK lines join
/// without spaces.
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

/// OCR lines -> paragraphs: line-level results merged by the same gap rule;
/// `size` carries the paragraph's line-height union for sub_type heuristics,
/// `confidence` is the line minimum.
fn ocr_lines_to_paragraphs(lines: &[OcrLine]) -> Vec<Para> {
    let mut sorted: Vec<&OcrLine> = lines.iter().filter(|l| !l.text.trim().is_empty()).collect();
    sorted.sort_by(|a, b| a.y.partial_cmp(&b.y).unwrap_or(std::cmp::Ordering::Equal));
    if sorted.is_empty() {
        return Vec::new();
    }
    let mut heights: Vec<f64> = sorted.iter().map(|l| l.h).collect();
    let median_h = median(&mut heights).unwrap_or(0.02).max(0.005);

    let mut paragraphs: Vec<Para> = Vec::new();
    let mut current: Vec<&OcrLine> = Vec::new();
    let flush = |current: &mut Vec<&OcrLine>, paragraphs: &mut Vec<Para>| {
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
            let size = current.iter().map(|l| l.h).fold(0.0f64, f64::max);
            paragraphs.push(Para {
                text,
                rects: current
                    .iter()
                    .map(|l| NormRect { x: l.x, y: l.y, w: l.w, h: l.h })
                    .collect(),
                size,
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
// Noise removal
// =============================================================================

fn in_margin(rect: &NormRect) -> bool {
    let cy = rect.y + rect.h / 2.0;
    !(MARGIN_FRACTION..=(1.0 - MARGIN_FRACTION)).contains(&cy)
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
// Formula detection (whole-paragraph display formulas)
// =============================================================================

/// Page-wide statistics that keep per-char formula signals from firing on
/// the whole page.
#[derive(Debug, Clone, Copy)]
struct MathSignals {
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

/// Whether a font name belongs to a math-ONLY family. Deliberately narrow:
/// broad `CM`/`MT`/`TEX` prefixes are NOT used because LaTeX documents set
/// their BODY text in Computer Modern (a real regression in the retired
/// pipeline flagged whole books as formulas).
fn is_math_font_name(name: &str) -> bool {
    let base = name.split('+').next_back().unwrap_or(name);
    let upper = base.trim().to_ascii_uppercase();
    let prefixes = [
        "CMMI", "CMSY", "CMEX", "MTMI", "MTSY", "MTEX", "MSAM", "MSBM", "LASY", "EUFM",
        "EUSM", "RSFS", "TXMI", "TXSY", "TXEX", "PXMI", "PXSY", "PXEX", "WASY",
    ];
    if prefixes.iter().any(|p| upper.starts_with(p)) {
        return true;
    }
    if upper.contains("MATH") {
        return true;
    }
    [
        "SYMBOL", "STIX", "XITS", "ASANA", "NEO EULER", "NEWCM", "EUCLID",
    ]
    .iter()
    .any(|p| upper.contains(p))
}

/// A character whose presence is a reliable, font-independent signal of
/// mathematics: operators, relations, arrows and Greek letters.
fn is_strong_math_char(c: char) -> bool {
    matches!(c,
        '+' | '-' | '=' | '<' | '>' | '*' | '/' | '^' | '_' | '|'
        | '±' | '∓' | '×' | '÷' | '⋅' | '·' | '∘' | '∗' | '⊕' | '⊗' | '⊙' | '⊘' | '⊥' | '∝'
        | '∑' | '∏' | '∫' | '∮' | '√' | '∞' | '∂' | '∇' | '¬'
        | '≤' | '≥' | '≠' | '≈' | '≃' | '≍' | '≐' | '≅' | '≡' | '≢' | '∼' | '≪' | '≫'
        | '∈' | '∉' | '∋' | '⊂' | '⊃' | '⊆' | '⊇'
        | '→' | '←' | '↔' | '↦' | '⇀' | '↼' | '↑' | '↓' | '⇑' | '⇓' | '↕' | '⇕'
        | '⇒' | '⇐' | '⇔' | '⊢' | '⊣' | '⊨'
        | '∀' | '∃' | '⟨' | '⟩' | '⟪' | '⟫' | '〈' | '〉'
        | '⌊' | '⌋' | '⌈' | '⌉' | '∥' | '∦' | '∠' | '∵' | '∴'
        | '′' | '″' | '‵'
        | 'α'..='ω' | 'Α'..='Ω'
    )
}

/// Content gate: a run is mathematics only when it contains no ordinary word
/// (a run of >= 3 alphabetic chars) AND at least one strong math operator.
pub fn text_looks_like_formula(text: &str) -> bool {
    let mut strong = 0usize;
    let mut run = 0usize;
    for c in text.chars() {
        if c.is_alphabetic() {
            run += 1;
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
        if ratio < s.median_ratio * 0.82 || ratio > s.median_ratio * 1.22 {
            return true;
        }
    }
    if c.angle.abs() > 1.0 {
        return true;
    }
    false
}

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

/// Fraction of non-whitespace chars that are structural symbols.
fn symbol_fraction(text: &str) -> f64 {
    let mut total = 0usize;
    let mut symbols = 0usize;
    for c in text.chars() {
        if c.is_whitespace() {
            continue;
        }
        total += 1;
        if !c.is_alphanumeric() {
            symbols += 1;
        }
    }
    if total == 0 {
        0.0
    } else {
        symbols as f64 / total as f64
    }
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

fn union_and_max_line(rects: &[NormRect]) -> (NormRect, f64) {
    let mut x0 = f64::MAX;
    let mut y0 = f64::MAX;
    let mut x1 = 0.0f64;
    let mut y1 = 0.0f64;
    let mut max_w = 0.0f64;
    for r in rects {
        x0 = x0.min(r.x);
        y0 = y0.min(r.y);
        x1 = x1.max(r.x + r.w);
        y1 = y1.max(r.y + r.h);
        max_w = max_w.max(r.w);
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

/// Whether a paragraph is a display formula and must keep its original
/// pixels (never translated). Text-layer path only: uses per-char math
/// signals (font families, sub/superscript scale, symbol flags).
fn is_whole_paragraph_formula(
    text: &str,
    rects: &[NormRect],
    math_ratio: f64,
    math_alpha_ratio: f64,
    wide_p95: f64,
) -> bool {
    if text.trim().is_empty() || rects.is_empty() {
        return false;
    }
    if math_ratio >= 0.8 && text_looks_like_formula(text) {
        return true;
    }
    if math_alpha_ratio >= 0.6 && count_alpha_runs(text, 4) <= 1 {
        return true;
    }
    let (union, max_line_w) = union_and_max_line(rects);
    let cx = union.x + union.w / 2.0;
    let tol = if ends_with_eq_number(text) { 0.16 } else { 0.06 };
    if is_centered_short(max_line_w, cx, wide_p95, tol)
        && (math_ratio >= 0.12 || text_looks_like_formula(text))
    {
        return true;
    }
    if math_ratio >= 0.9
        && count_alpha_runs(text, 4) <= 6
        && symbol_fraction(text) >= 0.3
        && text.chars().any(is_strong_math_char)
    {
        return true;
    }
    false
}

/// Per-paragraph median rendered font size (points) from the chars inside
/// its line rects; falls back to the line-height proxy when no chars match.
fn paragraph_font_size(p: &Para, chars: &[PageChar]) -> f64 {
    let mut sizes: Vec<f64> = Vec::new();
    for c in chars {
        if c.ch.trim().is_empty() || c.scaled_size <= 0.01 {
            continue;
        }
        let cx = c.x + c.w / 2.0;
        let cy = c.y + c.h / 2.0;
        let inside = p.rects.iter().any(|r| {
            cx >= r.x - 0.004 && cx <= r.x + r.w + 0.004 && cy >= r.y - 0.004 && cy <= r.y + r.h + 0.004
        });
        if inside {
            sizes.push(c.scaled_size);
        }
    }
    median(&mut sizes).unwrap_or(p.size)
}

/// Per-paragraph math ratios from the chars whose center falls inside the
/// paragraph's line rects.
fn paragraph_math_ratios(p: &Para, chars: &[PageChar], signals: &MathSignals) -> (f64, f64) {
    let mut total = 0usize;
    let mut math = 0usize;
    let mut alpha = 0usize;
    let mut alpha_math = 0usize;
    for c in chars {
        if c.ch.trim().is_empty() {
            continue;
        }
        let cx = c.x + c.w / 2.0;
        let cy = c.y + c.h / 2.0;
        let inside = p
            .rects
            .iter()
            .any(|r| cx >= r.x - 0.004 && cx <= r.x + r.w + 0.004 && cy >= r.y - 0.004 && cy <= r.y + r.h + 0.004);
        if !inside {
            continue;
        }
        total += 1;
        let is_math = is_math_char(c, signals);
        if is_math {
            math += 1;
        }
        if c.ch.chars().next().map(|ch| ch.is_alphabetic()).unwrap_or(false) {
            alpha += 1;
            if is_math {
                alpha_math += 1;
            }
        }
    }
    let math_ratio = if total > 0 { math as f64 / total as f64 } else { 0.0 };
    let alpha_ratio = if alpha > 0 {
        alpha_math as f64 / alpha as f64
    } else {
        0.0
    };
    (math_ratio, alpha_ratio)
}

// =============================================================================
// sub_type heuristics
// =============================================================================

/// Caption prefixes in both source languages the reader sees.
fn looks_like_caption(text: &str) -> bool {
    let t = text.trim_start();
    let lower = t.to_ascii_lowercase();
    for prefix in ["figure", "fig.", "fig ", "table", "tab.", "chart", "scheme", "equation"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let rest = rest.trim_start();
            if rest.starts_with(|c: char| c.is_ascii_digit()) {
                return true;
            }
        }
    }
    for prefix in ["图", "表"] {
        if let Some(rest) = t.strip_prefix(prefix) {
            let rest = rest.trim_start_matches([' ', '.', '·', '：', ':']);
            if rest.starts_with(|c: char| c.is_ascii_digit() || ('１'..='９').contains(&c)) {
                return true;
            }
        }
    }
    false
}

fn looks_like_abstract(text: &str) -> bool {
    let t = text.trim_start();
    let lower = t.to_ascii_lowercase();
    if let Some(rest) = lower.strip_prefix("abstract") {
        // Word boundary: "Abstract: ..." / "Abstract ..." yes, "Abstraction"
        // no.
        if lower.starts_with("abstract ") {
            return true;
        }
        let rest = rest.trim_start();
        if rest.is_empty() || rest.starts_with([':', '.', '—', '-', '：']) {
            return true;
        }
    }
    t.starts_with("摘要")
}

/// Classifies a paragraph into the flat `sub_type` vocabulary the RetainPDF
/// adapter maps to layout/semantic roles. [body_size] is the page's body
/// reference (median char height for text pages, median paragraph height for
/// OCR pages); a paragraph at least 15% larger is a heading candidate.
fn sub_type_for(p: &Para, body_size: f64, in_top_margin: bool, in_bottom_margin: bool) -> &'static str {
    if looks_like_abstract(&p.text) {
        return "abstract";
    }
    if looks_like_caption(&p.text) {
        return "caption";
    }
    if in_top_margin {
        return "header";
    }
    if in_bottom_margin {
        // Small text in the bottom band is a footnote; normal-size text
        // there (rare) falls through to footer treatment.
        return if p.size > 0.0 && body_size > 0.0 && p.size < body_size * 0.92 {
            "footnote"
        } else {
            "footer"
        };
    }
    let short = p.text.chars().count() <= 120;
    if body_size > 0.0 && p.size >= body_size * 1.15 && short && !p.text.ends_with('.') {
        // Titles AND section headings -- never `title`: the flat adapter
        // locks titles as no-translate (see module docs).
        return "heading";
    }
    "body"
}

// =============================================================================
// Document building
// =============================================================================

/// Per-page extraction state from pass 1 (one document handle).
struct PageData {
    chars: Vec<PageChar>,
    margins: Vec<String>,
    width: f64,
    height: f64,
}

/// Builds the flat provider payload for one PDF.
///
/// Text-layer pages are extracted directly; pages without a text layer are
/// OCR'd locally (cache first, then the engine). [on_progress] receives
/// `(pages_done, pages_total, detail)`.
pub fn build_flat_document(
    stored_path: &str,
    book_id: i64,
    on_progress: &mut impl FnMut(i64, i64, String),
) -> AppResult<FlatDocument> {
    // Pass 1: per-page chars + margins + page size (one document handle).
    let pages_data: Vec<PageData> = crate::pdf::with_document_file(stored_path, |doc| {
        let count = doc.pages().len() as i64;
        if count <= 0 {
            return Err(AppError::Internal("PDF 没有页面".into()));
        }
        let mut out = Vec::with_capacity(count as usize);
        for page in 1..=count {
            let pg = doc.pages().get((page - 1) as pdfium_render::prelude::PdfPageIndex)?;
            let width = pg.width().value as f64;
            let height = pg.height().value as f64;
            let chars = collect_page_chars(doc, page)?;
            let margins = margin_line_texts(&chars);
            out.push(PageData {
                chars,
                margins,
                width,
                height,
            });
        }
        Ok(out)
    })?;

    let total = pages_data.len() as i64;
    let mut pages = Vec::with_capacity(pages_data.len());
    for (idx, data) in pages_data.iter().enumerate() {
        let page_no = idx as i64 + 1;
        on_progress(page_no - 1, total, format!("构建文档结构 {page_no}/{total}"));

        let neighbors: Vec<String> = {
            let mut n = Vec::new();
            if idx > 0 {
                n.extend(pages_data[idx - 1].margins.iter().cloned());
            }
            if idx + 1 < pages_data.len() {
                n.extend(pages_data[idx + 1].margins.iter().cloned());
            }
            n
        };

        let mut blocks: Vec<FlatBlock> = Vec::new();
        if data.chars.iter().any(|c| !c.ch.trim().is_empty()) {
            // --- text-layer path ---
            let paras = fallback_paragraphs(&data.chars);
            let signals = math_signals(&data.chars);
            let wide_p95 = p95_width(
                paras
                    .iter()
                    .flat_map(|p| p.rects.iter().map(|r| r.w))
                    .filter(|w| *w > 0.0)
                    .collect(),
            );
            let mut char_sizes: Vec<f64> = data
                .chars
                .iter()
                .filter(|c| !c.ch.trim().is_empty() && c.scaled_size > 0.01)
                .map(|c| c.scaled_size)
                .collect();
            let body_size = median(&mut char_sizes).unwrap_or(0.0);

            for mut p in paras {
                let first = p.rects.first().copied();
                if is_noise(&p.text, first, &neighbors) {
                    continue;
                }
                // Real font size (points) beats glyph tight-bounds height as
                // the size proxy: caps-only headings have SHORTER glyph boxes
                // than lowercase body text of a smaller size.
                p.size = paragraph_font_size(&p, &data.chars);
                let (math_ratio, alpha_ratio) =
                    paragraph_math_ratios(&p, &data.chars, &signals);
                let is_formula = is_whole_paragraph_formula(
                    &p.text,
                    &p.rects,
                    math_ratio,
                    alpha_ratio,
                    wide_p95,
                );
                let (kind, sub_type) = if is_formula {
                    ("formula", "display_formula")
                } else {
                    let (top, bottom) = margin_flags(first);
                    ("text", sub_type_for(&p, body_size, top, bottom))
                };
                blocks.push(flat_block(&p.text, &p.rects, data, kind, sub_type));
            }
        } else {
            // --- scanned page: local OCR ---
            let lines = ocr_page_lines(stored_path, book_id, page_no, on_progress, total)?;
            let paras = ocr_lines_to_paragraphs(&lines);
            let mut sizes: Vec<f64> = paras.iter().map(|p| p.size).filter(|s| *s > 0.0).collect();
            let body_size = median(&mut sizes).unwrap_or(0.0);
            for p in paras {
                let first = p.rects.first().copied();
                if is_noise(&p.text, first, &neighbors) {
                    continue;
                }
                let (top, bottom) = margin_flags(first);
                // OCR pages carry no font metadata: display formulas are
                // detected from the text shape alone (pure symbol, no words).
                let is_formula =
                    text_looks_like_formula(&p.text) && symbol_fraction(&p.text) >= 0.3;
                let (kind, sub_type) = if is_formula {
                    ("formula", "display_formula")
                } else {
                    ("text", sub_type_for(&p, body_size, top, bottom))
                };
                blocks.push(flat_block(&p.text, &p.rects, data, kind, sub_type));
            }
        }

        pages.push(FlatPage {
            page: page_no,
            width: data.width,
            height: data.height,
            unit: "pt",
            blocks,
        });
    }
    on_progress(total, total, "文档结构就绪".into());
    Ok(FlatDocument {
        provider: "generic_flat_ocr",
        pages,
    })
}

fn margin_flags(first: Option<NormRect>) -> (bool, bool) {
    match first {
        Some(r) => {
            let cy = r.y + r.h / 2.0;
            (cy < MARGIN_FRACTION, cy > 1.0 - MARGIN_FRACTION)
        }
        None => (false, false),
    }
}

fn flat_block(text: &str, rects: &[NormRect], data: &PageData, kind: &str, sub_type: &str) -> FlatBlock {
    let (union, _) = union_and_max_line(rects);
    // Clamp to the page: a long line can overflow the mediabox.
    let x0 = union.x.clamp(0.0, 1.0);
    let y0 = union.y.clamp(0.0, 1.0);
    let x1 = (union.x + union.w).clamp(0.0, 1.0);
    let y1 = (union.y + union.h).clamp(0.0, 1.0);
    FlatBlock {
        kind: kind.to_string(),
        sub_type: sub_type.to_string(),
        bbox: [
            round2(x0 * data.width),
            round2(y0 * data.height),
            round2(x1 * data.width),
            round2(y1 * data.height),
        ],
        text: text.to_string(),
    }
}

fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}

/// OCR one page: cache first, then the local engine at [OCR_RENDER_SCALE].
fn ocr_page_lines(
    stored_path: &str,
    book_id: i64,
    page: i64,
    on_progress: &mut impl FnMut(i64, i64, String),
    total: i64,
) -> AppResult<Vec<OcrLine>> {
    {
        let conn = crate::db::db();
        if let Ok(Some(cached)) = crate::db::repository::ocr::get_page_ocr(&conn, book_id, page, OCR_MODE) {
            return Ok(cached.lines);
        }
    }
    let engine = crate::ocr::engine();
    if !engine.is_available() {
        return Err(AppError::Internal(format!(
            "第 {page} 页没有文字层，且本地 OCR 模型未安装（{}）",
            crate::ocr::StubOcrEngine::MISSING_MODELS
        )));
    }
    on_progress(page - 1, total, format!("识别扫描页 {page}/{total}"));
    let bmp = crate::pdf::render_page_file(stored_path, page - 1, OCR_RENDER_SCALE)?;
    if bmp.rgba.is_empty() {
        return Ok(Vec::new());
    }
    let img = crate::ocr::PageImage {
        rgba: &bmp.rgba,
        width: bmp.width,
        height: bmp.height,
    };
    let result = engine.scan(&img, OCR_MODE)?;
    {
        let conn = crate::db::db();
        let _ = crate::db::repository::ocr::save_page_ocr(&conn, book_id, page, OCR_MODE, &result);
    }
    Ok(result.lines)
}

// =============================================================================
// Text utilities
// =============================================================================

/// Ligature normalization + whitespace collapse.
fn normalize_text(s: &str) -> String {
    let s = s
        .replace('\u{FB00}', "ff")
        .replace('\u{FB01}', "fi")
        .replace('\u{FB02}', "fl")
        .replace('\u{FB03}', "ffi")
        .replace('\u{FB04}', "ffl")
        .replace(['\u{FB05}', '\u{FB06}'], "st")
        .replace('\u{00AD}', "");
    normalize_ws(&s)
}

fn normalize_ws(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn count_cjk(s: &str) -> usize {
    s.chars()
        .filter(|c| {
            matches!(c,
                '\u{4E00}'..='\u{9FFF}'
                | '\u{3400}'..='\u{4DBF}'
                | '\u{F900}'..='\u{FAFF}'
                | '\u{3000}'..='\u{303F}'
                | '\u{FF00}'..='\u{FFEF}')
        })
        .count()
}

fn median(values: &mut [f64]) -> Option<f64> {
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
        let joined = join_paragraph_text(&[
            line("continua-", 0.1, 0.1, 0.7, 0.02),
            line("tion follows", 0.1, 0.13, 0.6, 0.02),
        ]);
        assert_eq!(joined, "continuation follows");

        let joined = join_paragraph_text(&[
            line("state-of-", 0.1, 0.1, 0.5, 0.02),
            line("The-art", 0.1, 0.13, 0.5, 0.02),
        ]);
        assert_eq!(joined, "state-of- The-art");

        let joined = join_paragraph_text(&[
            line("量子力学", 0.1, 0.1, 0.5, 0.02),
            line("是物理学的分支", 0.1, 0.13, 0.7, 0.02),
        ]);
        assert_eq!(joined, "量子力学是物理学的分支");

        assert_eq!(normalize_text("ﬁle ﬂow"), "file flow");
    }

    #[test]
    fn ocr_lines_merge_by_gap_with_min_confidence() {
        let lines = vec![
            OcrLine { text: "第一段第一行".into(), x: 0.1, y: 0.10, w: 0.6, h: 0.02, confidence: 0.95 },
            OcrLine { text: "第一段第二行".into(), x: 0.1, y: 0.13, w: 0.6, h: 0.02, confidence: 0.75 },
            OcrLine { text: "第二段".into(), x: 0.1, y: 0.30, w: 0.3, h: 0.02, confidence: 0.90 },
        ];
        let paras = ocr_lines_to_paragraphs(&lines);
        assert_eq!(paras.len(), 2);
        assert_eq!(paras[0].text, "第一段第一行第一段第二行");
        assert_eq!(paras[1].text, "第二段");
    }

    #[test]
    fn formula_gate_keeps_words_as_prose() {
        assert!(text_looks_like_formula("E = mc^2"));
        assert!(text_looks_like_formula("α + β ≥ γ"));
        assert!(!text_looks_like_formula("state-of-the-art results"));
        assert!(!text_looks_like_formula("This is prose, not math."));
    }

    #[test]
    fn caption_and_abstract_detection() {
        assert!(looks_like_caption("Figure 3: Layout pipeline"));
        assert!(looks_like_caption("Fig. 2 — Results"));
        assert!(looks_like_caption("表 4 实验结果"));
        assert!(!looks_like_caption("Figures of speech"));
        assert!(looks_like_abstract("Abstract: We present..."));
        assert!(looks_like_abstract("摘要 本文提出"));
        assert!(!looks_like_abstract("Abstraction is key"));
    }

    #[test]
    fn sub_type_heading_by_size_and_short() {
        let p = Para {
            text: "2. Method".into(),
            rects: vec![NormRect { x: 0.1, y: 0.2, w: 0.3, h: 0.03 }],
            size: 0.03,
        };
        assert_eq!(sub_type_for(&p, 0.02, false, false), "heading");
        let body = Para { size: 0.02, ..p.clone() };
        assert_eq!(sub_type_for(&body, 0.02, false, false), "body");
        // Margin paragraphs are header/footer, never heading.
        assert_eq!(sub_type_for(&p, 0.02, true, false), "header");
        assert_eq!(sub_type_for(&body, 0.02, false, true), "footer");
    }

    #[test]
    fn noise_removes_page_numbers_and_repeated_margins() {
        let rect = Some(NormRect { x: 0.4, y: 0.97, w: 0.05, h: 0.015 });
        assert!(is_noise("12", rect, &[]));
        let rect = Some(NormRect { x: 0.1, y: 0.02, w: 0.3, h: 0.015 });
        assert!(is_noise("Journal of Testing", rect, &["Journal of Testing".into()]));
        assert!(!is_noise("Journal of Testing", rect, &[]));
        // Body paragraphs are never noise.
        let rect = Some(NormRect { x: 0.1, y: 0.5, w: 0.5, h: 0.02 });
        assert!(!is_noise("12", rect, &[]));
    }

    #[test]
    fn flat_json_shape_matches_adapter_contract() {
        let doc = FlatDocument {
            provider: "generic_flat_ocr",
            pages: vec![FlatPage {
                page: 1,
                width: 595.0,
                height: 842.0,
                unit: "pt",
                blocks: vec![FlatBlock {
                    kind: "text".into(),
                    sub_type: "body".into(),
                    bbox: [72.0, 120.0, 523.0, 240.0],
                    text: "hello".into(),
                }],
            }],
        };
        let v: serde_json::Value = serde_json::from_str(&doc.to_json()).unwrap();
        assert_eq!(v["provider"], "generic_flat_ocr");
        assert_eq!(v["pages"][0]["unit"], "pt");
        assert_eq!(v["pages"][0]["blocks"][0]["type"], "text");
        assert_eq!(v["pages"][0]["blocks"][0]["sub_type"], "body");
        assert_eq!(v["pages"][0]["blocks"][0]["bbox"][0], 72.0);
    }

    /// End-to-end extraction (no OCR, no LLM): build a two-page paper-style
    /// PDF with pdfium, run the real pipeline, assert heading/caption/formula
    /// classification, noise removal (repeated margin line + page numbers),
    /// paragraph merging and bbox sanity.
    ///
    /// Skips when libpdfium is unreachable (same pattern as the pdf module's
    /// concurrency test).
    #[test]
    fn builds_blocks_from_a_real_pdf() {
        use pdfium_render::prelude::*;

        let path = std::env::temp_dir().join(format!("rbwa_flat_ocr_{}.pdf", std::process::id()));
        let built = crate::pdf::with_pdfium_lock(|p| {
            let mut doc = p.create_new_pdf()?;
            let font = doc.fonts_mut().helvetica();
            {
                let mut page = doc.pages_mut().create_page_at_end(PdfPagePaperSize::a4())?;
                let objs = page.objects_mut();
                // Repeated margin header (removed on both pages via neighbors).
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(820.0),
                    "Journal of Flat OCR",
                    font,
                    PdfPoints::new(9.0),
                )?;
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
                    "The quick brown fox jumps over the lazy dog and this line looks like body text.",
                    font,
                    PdfPoints::new(11.0),
                )?;
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(636.0),
                    "A second line continues the same paragraph with more words.",
                    font,
                    PdfPoints::new(11.0),
                )?;
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(600.0),
                    "Figure 1: a caption line under a figure.",
                    font,
                    PdfPoints::new(10.0),
                )?;
                // Centered, symbol-dense line -> display formula.
                objs.create_text_object(
                    PdfPoints::new(280.0),
                    PdfPoints::new(560.0),
                    "E = mc2 + x2",
                    font,
                    PdfPoints::new(11.0),
                )?;
                // Page number in the bottom margin.
                objs.create_text_object(
                    PdfPoints::new(290.0),
                    PdfPoints::new(20.0),
                    "1",
                    font,
                    PdfPoints::new(10.0),
                )?;
            }
            {
                let mut page = doc.pages_mut().create_page_at_end(PdfPagePaperSize::a4())?;
                let objs = page.objects_mut();
                objs.create_text_object(
                    PdfPoints::new(60.0),
                    PdfPoints::new(820.0),
                    "Journal of Flat OCR",
                    font,
                    PdfPoints::new(9.0),
                )?;
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
                objs.create_text_object(
                    PdfPoints::new(290.0),
                    PdfPoints::new(20.0),
                    "2",
                    font,
                    PdfPoints::new(10.0),
                )?;
            }
            doc.save_to_file(&path)?;
            Ok(())
        });
        if built.is_err() {
            eprintln!("skipping: libpdfium not on the search path");
            return;
        }

        let doc = build_flat_document(path.to_str().unwrap(), 0, &mut |_, _, _| {})
            .expect("flat document");
        assert_eq!(doc.pages.len(), 2);
        assert_eq!(doc.provider, "generic_flat_ocr");

        let page1_texts: Vec<&str> = doc.pages[0].blocks.iter().map(|b| b.text.as_str()).collect();
        // Noise removed: repeated header + page number.
        assert!(
            !page1_texts.iter().any(|t| t.contains("Journal of Flat OCR")),
            "margin header must be removed: {page1_texts:?}"
        );
        assert!(!page1_texts.contains(&"1"), "page number must be removed");
        // Title -> heading (never `title`; see module docs).
        let title = doc.pages[0]
            .blocks
            .iter()
            .find(|b| b.text.contains("Layout-Preserving"))
            .expect("title block");
        assert_eq!(title.sub_type, "heading");

        // Paragraph lines merged into one body block.
        let body = doc.pages[0]
            .blocks
            .iter()
            .find(|b| b.text.starts_with("The quick brown fox"))
            .expect("body block");
        assert_eq!(body.sub_type, "body");
        assert!(body.text.contains("A second line continues the same paragraph"), "lines merged: {}", body.text);

        // Caption detection.
        let caption = doc.pages[0]
            .blocks
            .iter()
            .find(|b| b.text.starts_with("Figure 1"))
            .expect("caption block");
        assert_eq!(caption.sub_type, "caption");

        // Display formula.
        let formula = doc.pages[0]
            .blocks
            .iter()
            .find(|b| b.text.starts_with("E = mc2"))
            .expect("formula block");
        assert_eq!(formula.kind, "formula");

        // bbox sanity: PDF points, top-left origin, inside the page.
        for page in &doc.pages {
            for b in &page.blocks {
                let [x0, y0, x1, y1] = b.bbox;
                assert!(x0 >= 0.0 && y0 >= 0.0 && x1 <= page.width && y1 <= page.height, "{:?}", b.bbox);
                assert!(x0 < x1 && y0 < y1, "{:?}", b.bbox);
            }
        }
        // Page 2 heading.
        let h2 = doc.pages[1]
            .blocks
            .iter()
            .find(|b| b.text.contains("Method"))
            .expect("page-2 heading");
        assert_eq!(h2.sub_type, "heading");

        let _ = std::fs::remove_file(&path);
    }

    /// Manual cross-check helper: dump the flat JSON for a PDF given via
    /// `RBWA_FLAT_OCR_DUMP_PDF` to `RBWA_FLAT_OCR_DUMP_OUT`, so the output can
    /// be fed to the RetainPDF `normalize-ocr` CLI (engine smoke). Not run by
    /// default:
    ///
    /// ```text
    /// RBWA_FLAT_OCR_DUMP_PDF=/path/in.pdf RBWA_FLAT_OCR_DUMP_OUT=/path/out.json \
    ///   cargo test --all-features -- --ignored dump_flat_json
    /// ```
    #[test]
    #[ignore = "manual engine cross-check"]
    fn dump_flat_json() {
        let pdf = std::env::var("RBWA_FLAT_OCR_DUMP_PDF").expect("RBWA_FLAT_OCR_DUMP_PDF");
        let out = std::env::var("RBWA_FLAT_OCR_DUMP_OUT").expect("RBWA_FLAT_OCR_DUMP_OUT");
        let doc = build_flat_document(&pdf, 0, &mut |done, total, detail| {
            eprintln!("[{done}/{total}] {detail}");
        })
        .expect("flat document");
        std::fs::write(&out, doc.to_json()).expect("write dump");
        eprintln!("wrote {out}");
    }
}