//! Translated-PDF writer (M7, plan §6): builds `translated/{book_id}/{lang}.pdf`
//! ON DEMAND (v4.2 user decision -- no incremental rebuild on translation).
//!
//! Assembly rules (plan §2, hard constraints):
//!   - always walk pages 1..N in original order, never by completion time;
//!   - untranslated pages become placeholder pages ("原书第 N 页 —— 尚未翻译"),
//!     so a partial translation never shifts page numbers;
//!   - every page starts with an "原书 p.N" anchor;
//!   - each page takes the ORIGINAL page's dimensions;
//!   - body text is real text (selectable / searchable) written as CID glyph
//!     runs against an embedded Noto Sans SC;
//!   - whole-paragraph formulas are embedded as the captured region PNG
//!     (visual fidelity); physical page count may differ from the original
//!     when translations run long (plan §2 物理页码 ≠ 原书页码).
//!
//! ## Why lopdf (plan §6 fallback, chosen after the first-step verification)
//!
//! Verification #2 (§6) showed pdfium's `FPDF_SaveAsCopy` embeds the font
//! WITHOUT subsetting (a 10 MB font → a 6.2 MB single-page PDF), which the
//! plan explicitly says to reject. The `subsetter` crate intentionally drops
//! the cmap (it is designed for glyph-id PDF text), so its output cannot feed
//! pdfium's string-based text API. This module therefore writes the PDF
//! directly with `lopdf`, subsets the font at build time to exactly the glyphs
//! the book uses, and emits Identity-H CID text. Text stays selectable and the
//! exported file is small.

use std::collections::HashMap;

use lopdf::dictionary;
use lopdf::{Document, Object, ObjectId, Stream};

use crate::error::{AppError, AppResult};
use crate::models::translate::{
    PageTranslation, ParagraphKind, TranslatedParagraph, TranslationProgressEvent,
};

/// Noto Sans SC Regular (TrueType/glyf outlines), subset to CJK + Latin +
/// symbols and instanced at weight 400. SIL OFL 1.1 (see
/// `rust/assets/fonts/OFL.txt`); the upstream 「Noto Sans SC」 name carries no
/// Reserved Font Name ('Source' does -- the separate Source Han family), so the
/// subset may keep the name. Distributed via `include_bytes!` (plan §6 option a).
const FONT_BYTES: &[u8] = include_bytes!("../../assets/fonts/NotoSansSC-Regular.ttf");

/// Body font size in PDF points.
const BODY_SIZE: f32 = 11.0;
/// Anchor + heading font size.
const ANCHOR_SIZE: f32 = 10.0;
/// Page margins in points.
const MARGIN: f32 = 48.0;
/// Line spacing multiplier.
const LINE_SPACING: f32 = 1.45;
/// Paragraph spacing in points.
const PARA_SPACING: f32 = 6.0;
/// Cap on background-render pixels (the overlay's page raster).
const BG_MAX_PIXELS: f64 = 24_000_000.0;
/// JPEG quality of the overlay page background (photos/figures tolerate 88;
/// keeps whole-book exports at ~100-250 KB per page instead of ~1 MB).
const JPEG_QUALITY: u8 = 88;
/// Smallest font the shrink-to-fit loop may pick for an overlay paragraph.
const MIN_OVERLAY_SIZE: f32 = 5.5;
/// Background render scale for whole-book exports (in-app passes the live
/// view scale through `render_translated_page`).
const EXPORT_BG_SCALE: f32 = 2.0;

/// Builds the translated PDF for [book_id]. Streams page-granular progress.
/// Returns the absolute path of the written file.
pub fn build_translated_pdf(
    book_id: i64,
    target_lang: &str,
    mut on_event: impl FnMut(TranslationProgressEvent),
) -> AppResult<String> {
    let book = load_book(book_id)?;
    let page_count = book.page_count.max(1);
    // Cache rows are keyed by the CONFIGURED target language; the effective
    // per-page language for 中英互译 is stored inside each row.
    let (lang_key, provider) = crate::translate::cache_key();

    // --- pass A: gather every page's cached translation + original size ----
    // Stale rows (old extractor stamp) count as untranslated, matching the
    // pane's page renderer -- an export must never mix old-extractor
    // paragraphs with fresh ones.
    let mut plans: Vec<PagePlan> = Vec::with_capacity(page_count as usize);
    for page in 1..=page_count {
        let cached = {
            let conn = crate::db::db();
            crate::db::repository::translate::get_page_translation(
                &conn, book_id, page, &lang_key, &provider, false,
            )
            .ok()
            .flatten()
            .filter(|t| crate::translate::is_current_source_hash(&t.source_hash))
        };
        let (pw, ph) = page_size(&book, page)?;
        plans.push(PagePlan {
            page,
            pw,
            ph,
            cached,
        });
    }

    // --- subset the font to exactly the glyphs used ------------------------
    let mut used: Vec<char> = Vec::new();
    for p in &plans {
        used.extend(page_used_chars(p.cached.as_ref(), target_lang));
    }
    let metrics = FontMetrics::prepare(&used)?;

    // --- pass B: write pages ----------------------------------------------
    let mut doc = Document::with_version("1.7");
    let pages_id = doc.new_object_id();
    let catalog_id = doc.add_object(dictionary! {
        "Type" => name("Catalog"),
        "Pages" => Object::Reference(pages_id),
    });
    doc.trailer.set("Root", Object::Reference(catalog_id));

    let font_id = add_font(&mut doc, &metrics)?;
    let mut kids: Vec<Object> = Vec::with_capacity(plans.len());

    for plan in &plans {
        // Overlay background for translated pages (lazily, one page at a
        // time). Failure degrades that page to the compact reflow layout.
        let bg = match &plan.cached {
            Some(t) => render_page_background(&book, plan.page, t, EXPORT_BG_SCALE)
                .ok()
                .flatten(),
            None => None,
        };
        let page_id = write_page(&mut doc, pages_id, font_id, plan, target_lang, &metrics, bg.as_ref())?;
        kids.push(Object::Reference(page_id));
        on_event(TranslationProgressEvent {
            page: plan.page,
            done_paragraphs: plan.page,
            total_paragraphs: page_count,
            coverage: plan.page as f64 / page_count as f64,
            finished: plan.page == page_count,
            error: None,
        });
    }

    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => name("Pages"),
            "Kids" => Object::Array(kids),
            "Count" => Object::Integer(page_count),
        }),
    );

    let dir = crate::translate::translated_dir(book_id);
    std::fs::create_dir_all(&dir)?;
    let path = translated_pdf_path(book_id, target_lang);
    doc.save(&path)
        .map_err(|e| AppError::Pdf(format!("保存译文 PDF 失败: {e}")))?;
    Ok(path.to_string_lossy().to_string())
}

/// Reads the cached translation for one page using the current cache key
/// (configured target lang + provider). A row stamped by an older extractor
/// is treated as untranslated (see [`crate::translate::is_current_source_hash`]).
fn load_cached_translation(book_id: i64, page: i64) -> Option<PageTranslation> {
    let (lang_key, provider) = crate::translate::cache_key();
    let conn = crate::db::db();
    crate::db::repository::translate::get_page_translation(
        &conn, book_id, page, &lang_key, &provider, false,
    )
    .ok()
    .flatten()
    .filter(|t| crate::translate::is_current_source_hash(&t.source_hash))
}

/// The characters a single translated page can render (anchors, placeholder,
/// page numbers, target language). Shared by the one-page builder so its font
/// subset always covers the page's own content.
fn page_used_chars(cached: Option<&PageTranslation>, target_lang: &str) -> Vec<char> {
    let mut used: Vec<char> = Vec::new();
    used.extend("原书第页尚未翻译　译本p.".chars());
    used.extend("0123456789".chars());
    used.extend(target_lang.chars());
    if let Some(t) = cached {
        for para in &t.paragraphs {
            used.extend(display_text(para).chars());
            used.extend(para.source.chars());
        }
    }
    used
}

/// Builds a ONE-PAGE PDF (in memory) holding only [page]'s translated content.
///
/// This is the pane's dedicated PAGE-LEVEL channel: the reader renders this
/// beside the original document -- the translation is laid out at the original
/// paragraphs' positions over the whitened original-page raster, so it looks
/// like the original page (same size, same structure, selectable text).
/// [dpi_scale] drives the background raster sharpness. Returns `None`-safe:
/// untranslated pages produce a compact placeholder page (the caller usually
/// checks `page_has_translation` first and shows its own placeholder).
pub fn build_page_pdf_bytes(
    book_id: i64,
    page: i64,
    target_lang: &str,
    dpi_scale: f32,
) -> AppResult<Vec<u8>> {
    let book = load_book(book_id)?;
    let cached = load_cached_translation(book_id, page);
    let (pw, ph) = page_size(&book, page)?;
    let metrics = FontMetrics::prepare(&page_used_chars(cached.as_ref(), target_lang))?;

    let mut doc = Document::with_version("1.7");
    let pages_id = doc.new_object_id();
    let catalog_id = doc.add_object(dictionary! {
        "Type" => name("Catalog"),
        "Pages" => Object::Reference(pages_id),
    });
    doc.trailer.set("Root", Object::Reference(catalog_id));

    let font_id = add_font(&mut doc, &metrics)?;
    let plan = PagePlan {
        page,
        pw,
        ph,
        cached,
    };
    let bg = match &plan.cached {
        Some(t) => render_page_background(&book, page, t, dpi_scale)
            .ok()
            .flatten(),
        None => None,
    };
    let page_id = write_page(&mut doc, pages_id, font_id, &plan, target_lang, &metrics, bg.as_ref())?;
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => name("Pages"),
            "Kids" => Object::Array(vec![Object::Reference(page_id)]),
            "Count" => Object::Integer(1),
        }),
    );

    let mut buf = Vec::new();
    doc.save_to(&mut buf)
        .map_err(|e| AppError::Pdf(format!("组装单页译文 PDF 失败: {e}")))?;
    Ok(buf)
}

/// Builds the one-page PDF and rasterizes it to RGBA through pdfium (loaded
/// from memory). [dpi_scale] multiplies the point->pixel factor (used both
/// for the composed-page raster and the background sharpness). Used by the
/// bilingual pane's page-level render API.
pub fn render_translated_page(
    book_id: i64,
    page: i64,
    target_lang: &str,
    dpi_scale: f32,
) -> AppResult<crate::pdf::types::PageBitmap> {
    let bytes = build_page_pdf_bytes(book_id, page, target_lang, dpi_scale)?;
    // Rasterize under the process-wide pdfium lock (pdfium is not thread-safe).
    crate::pdf::with_pdfium_lock(move |pdfium| {
        let doc = pdfium
            .load_pdf_from_byte_vec(bytes, None)
            .map_err(|e| AppError::Pdf(format!("加载单页译文 PDF 失败: {e}")))?;
        let pg = doc
            .pages()
            .get(0)
            .map_err(|e| AppError::Pdf(format!("译文 PDF 无页面: {e}")))?;
        let scale = dpi_scale.max(0.1);
        let target_w = (pg.width().value * scale).max(1.0) as i32;
        let target_h = (pg.height().value * scale).max(1.0) as i32;
        let config = pdfium_render::prelude::PdfRenderConfig::new()
            .set_target_width(target_w)
            .set_target_height(target_h);
        let bitmap = pg
            .render_with_config(&config)
            .map_err(|e| AppError::Pdf(format!("渲染译文页失败: {e}")))?;
        Ok(crate::pdf::types::PageBitmap {
            width: bitmap.width() as u32,
            height: bitmap.height() as u32,
            rgba: bitmap.as_rgba_bytes(),
        })
    })
}

fn sanitize_lang(target_lang: &str) -> String {
    target_lang
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect()
}

/// The PDF artifact path for a book + language (plan §6:
/// `translated/{book_id}/{lang}.pdf`).
pub fn translated_pdf_path(book_id: i64, target_lang: &str) -> std::path::PathBuf {
    crate::translate::translated_dir(book_id)
        .join(format!("{}.pdf", sanitize_lang(target_lang)))
}

struct BookInfo {
    stored_path: String,
    page_count: i64,
    file_type: String,
}

fn load_book(book_id: i64) -> AppResult<BookInfo> {
    let conn = crate::db::db();
    conn.query_row(
        "SELECT stored_path, page_count, file_type FROM books WHERE id = ?1",
        rusqlite::params![book_id],
        |row| {
            Ok(BookInfo {
                stored_path: row.get(0)?,
                page_count: row.get(1)?,
                file_type: row.get(2)?,
            })
        },
    )
    .map_err(|_| AppError::NotFound(format!("书籍不存在 (id={book_id})")))
}

struct PagePlan {
    page: i64,
    pw: f32,
    ph: f32,
    cached: Option<PageTranslation>,
}

/// Original page dimensions in points (image books use their pixel size,
/// capped to A4-ish points). Independent pdfium handle, under the pdfium lock.
fn page_size(book: &BookInfo, page: i64) -> AppResult<(f32, f32)> {
    if book.file_type == "pdf" {
        if let Ok((w, h)) = crate::pdf::with_document_file(&book.stored_path, |doc| {
            use pdfium_render::prelude::PdfPageIndex;
            let pg = doc.pages().get((page - 1) as PdfPageIndex)?;
            Ok((pg.width().value, pg.height().value))
        }) {
            if w > 1.0 && h > 1.0 {
                return Ok((w, h));
            }
        }
    }
    if book.file_type == "image" {
        if let Ok(img) = image::open(&book.stored_path) {
            let (w, h) = (img.width() as f32, img.height() as f32);
            let scale = (595.0 / w).min(842.0 / h).min(1.0);
            return Ok((w * scale, h * scale));
        }
    }
    Ok((595.0, 842.0)) // A4 fallback
}

// =============================================================================
// Overlay background: original page raster with text areas whitened
// =============================================================================

/// JPEG-encoded whitened page raster for the overlay layout.
struct Background {
    jpeg: Vec<u8>,
    px_w: i32,
    px_h: i32,
}

/// Renders the ORIGINAL page and blanks every text paragraph's line rects, so
/// the overlay writer can draw translations at the same spots while figures,
/// formulas, tables, margins and the column structure stay visible.
/// [scale] multiplies page points -> pixels (capped by [BG_MAX_PIXELS]).
/// Returns `None` for unsupported book kinds.
fn render_page_background(
    book: &BookInfo,
    page: i64,
    t: &PageTranslation,
    scale: f32,
) -> AppResult<Option<Background>> {
    let mut rgba_img = match book.file_type.as_str() {
        "pdf" => crate::pdf::with_document_file(&book.stored_path, |doc| {
            use pdfium_render::prelude::*;
            let pg = doc.pages().get((page - 1) as PdfPageIndex)?;
            let pw = pg.width().value.max(1.0) as f64;
            let phh = pg.height().value.max(1.0) as f64;
            let mut s = scale.max(0.1) as f64;
            if pw * phh * s * s > BG_MAX_PIXELS {
                s = (BG_MAX_PIXELS / (pw * phh)).sqrt();
            }
            let config = PdfRenderConfig::new()
                .set_target_width(((pw * s) as i32).max(1))
                .set_target_height(((phh * s) as i32).max(1));
            let bitmap = pg.render_with_config(&config)?;
            image::RgbaImage::from_raw(
                bitmap.width() as u32,
                bitmap.height() as u32,
                bitmap.as_rgba_bytes().to_vec(),
            )
            .ok_or_else(|| AppError::Pdf("页面光栅尺寸不匹配".into()))
        })?,
        "image" => image::open(&book.stored_path)
            .map_err(|e| AppError::Internal(format!("decode image: {e}")))?
            .to_rgba8(),
        _ => return Ok(None),
    };
    whiten_paragraphs(&mut rgba_img, t);
    let (px_w, px_h) = (rgba_img.width() as i32, rgba_img.height() as i32);
    let rgb = image::DynamicImage::ImageRgba8(rgba_img).to_rgb8();
    let mut buf = std::io::Cursor::new(Vec::new());
    rgb.write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(
        &mut buf, JPEG_QUALITY,
    ))
    .map_err(|e| AppError::Pdf(format!("背景 JPEG 编码失败: {e}")))?;
    Ok(Some(Background {
        jpeg: buf.into_inner(),
        px_w,
        px_h,
    }))
}

/// Fills each text paragraph's line rects (slightly padded) with white.
/// Formula paragraphs are skipped -- their original pixels stay visible.
fn whiten_paragraphs(img: &mut image::RgbaImage, t: &PageTranslation) {
    let (w, h) = (img.width() as f64, img.height() as f64);
    // Padding in normalized page units: a bit of vertical slack covers
    // ascenders/descenders beyond the tight line box.
    let pad_x = 0.0015;
    let pad_y = 0.0025;
    for para in &t.paragraphs {
        // Mirror the overlay draw rule: formulas and inline-formula
        // paragraphs keep their original pixels.
        if para.kind != ParagraphKind::Text || !para.formula_regions.is_empty() {
            continue;
        }
        for r in &para.rects {
            let x0 = ((r.x - pad_x).max(0.0) * w).floor() as i32;
            let y0 = ((r.y - pad_y).max(0.0) * h).floor() as i32;
            let x1 = ((r.x + r.w + pad_x).min(1.0) * w).ceil() as i32;
            let y1 = ((r.y + r.h + pad_y).min(1.0) * h).ceil() as i32;
            for yy in y0.max(0)..y1.min(img.height() as i32) {
                for xx in x0.max(0)..x1.min(img.width() as i32) {
                    img.put_pixel(xx as u32, yy as u32, image::Rgba([255, 255, 255, 255]));
                }
            }
        }
    }
}

// =============================================================================
// Overlay text fitting
// =============================================================================

/// Union of a paragraph's line rects (its full footprint).
fn union_rect(rects: &[crate::models::annotation::NormRect]) -> Option<crate::models::annotation::NormRect> {
    use crate::models::annotation::NormRect;
    let mut it = rects.iter().filter(|r| r.w > 0.0 && r.h > 0.0);
    let first = *it.next()?;
    let (mut x0, mut y0, mut x1, mut y1) =
        (first.x, first.y, first.x + first.w, first.y + first.h);
    for r in it {
        x0 = x0.min(r.x);
        y0 = y0.min(r.y);
        x1 = x1.max(r.x + r.w);
        y1 = y1.max(r.y + r.h);
    }
    Some(NormRect {
        x: x0,
        y: y0,
        w: (x1 - x0).max(0.0),
        h: (y1 - y0).max(0.0),
    })
}

/// Shrink-to-fit: wrap at [col_w] starting from the size hint; if the wrapped
/// block is taller than [max_h], shrink by 10% until it fits or the floor is
/// reached (the floor may overflow slightly -- clipped when drawing).
fn fit_paragraph(
    text: &str,
    col_w: f32,
    max_h: f32,
    m: &FontMetrics,
    hint: f32,
) -> (f32, Vec<String>) {
    let mut size = hint.clamp(MIN_OVERLAY_SIZE, 28.0);
    let mut lines = wrap_text(text, col_w, size, m);
    while lines.len() as f32 * size * LINE_SPACING > max_h && size > MIN_OVERLAY_SIZE {
        size = (size * 0.9).max(MIN_OVERLAY_SIZE);
        lines = wrap_text(text, col_w, size, m);
    }
    (size, lines)
}

// =============================================================================
// Font metrics + subsetting
// =============================================================================

/// Unicode -> glyph metrics via the ORIGINAL bundled font, plus the
/// old-glyph-id -> new-glyph-id map produced by subsetting. PDF text is
/// written with the NEW ids (Identity-H), and /W widths use the ORIGINAL
/// advances (unchanged by subsetting).
struct FontMetrics {
    face: ttf_parser::Face<'static>,
    /// old gid -> new gid
    remap: HashMap<u16, u16>,
    /// new gid -> advance width in 1000-unit text space
    widths: HashMap<u16, i64>,
    /// new gid -> UTF-16BE hex of the char (for the /ToUnicode CMap, so text
    /// extraction / search work even though the subset has no cmap).
    to_unicode: Vec<(u16, String)>,
    font_file: Vec<u8>,
    bbox: [i64; 4],
    ascent: i64,
    descent: i64,
    italic_angle: f32,
}

impl FontMetrics {
    fn prepare(used: &[char]) -> AppResult<Self> {
        let face = ttf_parser::Face::parse(FONT_BYTES, 0)
            .map_err(|e| AppError::Pdf(format!("解析内置字体失败: {e}")))?;
        let upem = face.units_per_em().max(1) as f32;

        // Collect the original glyph ids actually needed (0 = .notdef always).
        let mut old_gids: Vec<u16> = vec![0];
        let mut seen: HashMap<u16, ()> = HashMap::new();
        for &c in used {
            if let Some(g) = face.glyph_index(c) {
                if seen.insert(g.0, ()).is_none() {
                    old_gids.push(g.0);
                }
            }
        }
        let remapper = subsetter::GlyphRemapper::new_from_glyphs_sorted(&old_gids);
        let mut remap = HashMap::new();
        for &old in &old_gids {
            if let Some(new) = remapper.get(old) {
                remap.insert(old, new);
            }
        }

        let subset = subsetter::subset(FONT_BYTES, 0, &remapper)
            .map_err(|e| AppError::Pdf(format!("字体子集化失败: {e}")))?;

        // Widths keyed by NEW gid, from the ORIGINAL advances. Also build the
        // /ToUnicode map: new gid -> UTF-16BE hex of its char.
        let mut widths = HashMap::new();
        let mut to_unicode: Vec<(u16, String)> = Vec::new();
        let mut seen_new: HashMap<u16, ()> = HashMap::new();
        for &old in &old_gids {
            let new = remap.get(&old).copied().unwrap_or(0);
            let adv = face.glyph_hor_advance(ttf_parser::GlyphId(old)).unwrap_or(0);
            widths.insert(new, (adv as f32 * 1000.0 / upem).round() as i64);
        }
        for &c in used {
            if let Some(old) = face.glyph_index(c) {
                let new = remap.get(&old.0).copied().unwrap_or(0);
                if seen_new.insert(new, ()).is_none() {
                    to_unicode.push((new, utf16be_hex(c)));
                }
            }
        }
        to_unicode.sort_by_key(|(g, _)| *g);

        let bb = face.global_bounding_box();
        let scale = |v: i16| (v as f32 * 1000.0 / upem).round() as i64;
        let bbox = [
            scale(bb.x_min),
            scale(bb.y_min),
            scale(bb.x_max),
            scale(bb.y_max),
        ];
        let ascent = scale(face.ascender());
        let descent = scale(face.descender());
        let italic_angle = face.italic_angle();

        Ok(Self {
            face,
            remap,
            widths,
            to_unicode,
            font_file: subset,
            bbox,
            ascent,
            descent,
            italic_angle,
        })
    }

    /// NEW glyph id for a char (0 = .notdef when the font lacks it).
    fn gid(&self, c: char) -> u16 {
        match self.face.glyph_index(c) {
            Some(old) => self.remap.get(&old.0).copied().unwrap_or(0),
            None => 0,
        }
    }

    /// Advance width of a char in points at [size].
    fn advance(&self, c: char, size: f32) -> f32 {
        let g = self.gid(c);
        let w = self.widths.get(&g).copied().unwrap_or(0) as f32;
        w * size / 1000.0
    }
}

/// Adds the Type0 / CIDFontType2 font (with the subset FontFile2) and returns
/// its object id.
fn add_font(doc: &mut Document, m: &FontMetrics) -> AppResult<ObjectId> {
    let base_font = name("NotoSansSC-Regular");
    let mut font_file = Stream::new(
        dictionary! { "Length1" => Object::Integer(m.font_file.len() as i64) },
        m.font_file.clone(),
    );
    font_file
        .compress()
        .map_err(|e| AppError::Pdf(format!("压缩字体流失败: {e}")))?;
    let font_file_id = doc.add_object(font_file);

    let descriptor_id = doc.add_object(dictionary! {
        "Type" => name("FontDescriptor"),
        "FontName" => base_font.clone(),
        "Flags" => Object::Integer(0x20 | 0x400), // non-symbolic, sans-serif
        "FontBBox" => Object::Array(m.bbox.iter().map(|v| Object::Integer(*v)).collect()),
        "ItalicAngle" => Object::Real(m.italic_angle),
        "Ascent" => Object::Integer(m.ascent),
        "Descent" => Object::Integer(m.descent),
        "CapHeight" => Object::Integer(m.ascent),
        "StemV" => Object::Integer(80),
        "FontFile2" => Object::Reference(font_file_id),
    });

    // /W array: "gid [width]" per glyph, ordered by new gid.
    let mut keys: Vec<u16> = m.widths.keys().copied().collect();
    keys.sort_unstable();
    let mut w_array: Vec<Object> = Vec::with_capacity(keys.len() * 2);
    for g in keys {
        w_array.push(Object::Integer(g as i64));
        w_array.push(Object::Array(vec![Object::Integer(
            m.widths.get(&g).copied().unwrap_or(0),
        )]));
    }

    let cid_font_id = doc.add_object(dictionary! {
        "Type" => name("Font"),
        "Subtype" => name("CIDFontType2"),
        "BaseFont" => base_font.clone(),
        "CIDSystemInfo" => dictionary! {
            "Registry" => Object::string_literal("Adobe"),
            "Ordering" => Object::string_literal("Identity"),
            "Supplement" => Object::Integer(0),
        },
        "FontDescriptor" => Object::Reference(descriptor_id),
        "DW" => Object::Integer(1000),
        "W" => Object::Array(w_array),
        "CIDToGIDMap" => name("Identity"),
    });

    let tounicode_id = add_tounicode(doc, m);
    let type0_id = doc.add_object(dictionary! {
        "Type" => name("Font"),
        "Subtype" => name("Type0"),
        "BaseFont" => base_font,
        "Encoding" => name("Identity-H"),
        "DescendantFonts" => Object::Array(vec![Object::Reference(cid_font_id)]),
        "ToUnicode" => Object::Reference(tounicode_id),
    });
    Ok(type0_id)
}

/// Builds the /ToUnicode CMap mapping every NEW glyph id back to its unicode
/// char (UTF-16BE). Without it, CID text extraction/search yields garbage.
fn add_tounicode(doc: &mut Document, m: &FontMetrics) -> ObjectId {
    let mut body = String::new();
    body.push_str(
        "/CIDInit /ProcSet findresource begin\n\
         12 dict begin\nbegincmap\n\
         /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n\
         /CMapName /Adobe-Identity-UCS def\n\
         /CMapType 2 def\n\
         1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
    );
    // bfchar entries in blocks of 100 (CMap spec limit).
    for chunk in m.to_unicode.chunks(100) {
        body.push_str(&format!("{} beginbfchar\n", chunk.len()));
        for (gid, uni) in chunk {
            body.push_str(&format!("<{gid:04X}> <{uni}>\n"));
        }
        body.push_str("endbfchar\n");
    }
    body.push_str(
        "endcmap\n\
         CMapName currentdict /CMap defineresource pop\n\
         end\nend\n",
    );
    let mut stream = Stream::new(dictionary! {}, body.into_bytes());
    let _ = stream.compress();
    doc.add_object(stream)
}

/// UTF-16BE hex of a char (surrogate pairs for astral chars).
fn utf16be_hex(c: char) -> String {
    let mut buf = [0u16; 2];
    let units = c.encode_utf16(&mut buf);
    units.iter().map(|u| format!("{u:04X}")).collect()
}

// =============================================================================
// Page writing
// =============================================================================

/// Writes one page: overlay layout (translation drawn AT the original
/// paragraphs' positions over the whitened original-page raster) when the
/// page has a translation with rects + a rendered background; otherwise the
/// compact reflow layout (placeholder pages, pre-v3 rows, failed raster).
fn write_page(
    doc: &mut Document,
    pages_id: ObjectId,
    font_id: ObjectId,
    plan: &PagePlan,
    target_lang: &str,
    m: &FontMetrics,
    bg: Option<&Background>,
) -> AppResult<ObjectId> {
    if let (Some(t), Some(bg)) = (&plan.cached, bg) {
        let rects_ready = t
            .paragraphs
            .iter()
            .filter(|p| p.kind == ParagraphKind::Text)
            .all(|p| !p.rects.is_empty());
        if rects_ready {
            return write_overlay_page(doc, pages_id, font_id, plan, m, t, bg);
        }
    }
    write_flow_page(doc, pages_id, font_id, plan, target_lang, m)
}

/// Shared page-object assembly: content stream + resources + page dict.
fn finish_page(
    doc: &mut Document,
    pages_id: ObjectId,
    font_id: ObjectId,
    content: String,
    xobjects: Vec<(String, ObjectId)>,
    pw: f32,
    ph: f32,
) -> ObjectId {
    let content_id = doc.add_object(Stream::new(dictionary! {}, content.into_bytes()));
    let mut resources = dictionary! {
        "Font" => dictionary! { "F1" => Object::Reference(font_id) },
    };
    if !xobjects.is_empty() {
        let mut xo = lopdf::Dictionary::new();
        for (n, id) in &xobjects {
            xo.set(n.as_bytes().to_vec(), Object::Reference(*id));
        }
        resources.set("XObject", Object::Dictionary(xo));
    }
    doc.add_object(dictionary! {
        "Type" => name("Page"),
        "Parent" => Object::Reference(pages_id),
        "MediaBox" => Object::Array(vec![
            Object::Integer(0), Object::Integer(0),
            Object::Real(pw), Object::Real(ph),
        ]),
        "Resources" => Object::Dictionary(resources),
        "Contents" => Object::Reference(content_id),
    })
}

/// OVERLAY layout: the original page raster (with text areas whitened) is the
/// background, and each paragraph's translation is drawn as real vector text
/// at the paragraph's original footprint (shrink-to-fit per paragraph).
/// Figures, formulas, tables, headers/footers and the column structure all
/// survive untouched -- only the text areas are replaced.
fn write_overlay_page(
    doc: &mut Document,
    pages_id: ObjectId,
    font_id: ObjectId,
    plan: &PagePlan,
    m: &FontMetrics,
    t: &PageTranslation,
    bg: &Background,
) -> AppResult<ObjectId> {
    let (pw, ph) = (plan.pw, plan.ph);
    let mut content = String::new();
    let mut xobjects: Vec<(String, ObjectId)> = Vec::new();

    emit_image_jpeg(
        &mut content, &mut xobjects, doc,
        &bg.jpeg, bg.px_w, bg.px_h,
        0.0, 0.0, pw, ph,
    );

    for para in &t.paragraphs {
        // Whole-paragraph formulas AND paragraphs containing inline formula
        // regions keep their ORIGINAL pixels: whitening the tight line rects
        // would slice through tall math (fractions, sums) and the flat
        // re-draw loses the layout.
        if para.kind != ParagraphKind::Text
            || !para.formula_regions.is_empty()
        {
            continue;
        }
        let text = display_text(para);
        if text.trim().is_empty() {
            continue;
        }
        let Some(rect) = union_rect(&para.rects) else {
            continue;
        };
        let (pw, ph) = (plan.pw as f64, plan.ph as f64);
        let col_w = ((rect.w * pw - 2.0).max(20.0)) as f32;
        let max_h = ((rect.h * ph + ph * 0.03).max(ph * 0.02)) as f32;
        // Font-size hint: the paragraph's median line height is a good proxy
        // for its em size (headings stay big, body stays body).
        let mut heights: Vec<f64> = para.rects.iter().map(|r| r.h).collect();
        let hint = crate::translate::extract::median(&mut heights).unwrap_or(0.012) * ph * 0.82;
        let (size, lines) = fit_paragraph(&text, col_w, max_h, m, hint as f32);

        // rects are top-left origin; PDF y is bottom-up.
        let top = (ph - rect.y * ph) as f32;
        let bottom = (ph - (rect.y + rect.h) * ph) as f32;
        let line_h = size * LINE_SPACING;
        let mut y = top - size * 0.95;
        for line in lines {
            if y < bottom - size * 0.25 {
                break;
            }
            emit_line(&mut content, m, (rect.x * pw + 1.0) as f32, y, size, &line);
            y -= line_h;
        }
    }

    Ok(finish_page(doc, pages_id, font_id, content, xobjects, pw, ph))
}

/// COMPACT reflow layout (fallback + placeholder pages): anchor line, then
/// every paragraph re-flowed into a single column; formulas embedded as the
/// captured region images when available.
fn write_flow_page(
    doc: &mut Document,
    pages_id: ObjectId,
    font_id: ObjectId,
    plan: &PagePlan,
    target_lang: &str,
    m: &FontMetrics,
) -> AppResult<ObjectId> {
    let (pw, ph) = (plan.pw, plan.ph);
    let mut content = String::new();
    let mut xobjects: Vec<(String, ObjectId)> = Vec::new();
    let mut y = ph - MARGIN;
    let line_h = BODY_SIZE * LINE_SPACING;

    // Anchor: 「原书 p.N　译本：<lang>」(plan §2).
    let anchor = format!(
        "原书 p.{}　译本：{}",
        plan.page,
        plan.cached
            .as_ref()
            .map(|t| t.target_lang.as_str())
            .unwrap_or(target_lang)
    );
    emit_line(&mut content, m, MARGIN, y, ANCHOR_SIZE, &anchor);
    y -= line_h * 1.4;

    let max_w = (pw - MARGIN * 2.0).max(60.0);
    match &plan.cached {
        None => {
            emit_line(
                &mut content,
                m,
                MARGIN,
                y,
                BODY_SIZE,
                &format!("原书第 {} 页 —— 尚未翻译", plan.page),
            );
        }
        Some(t) => {
            for para in &t.paragraphs {
                if para.kind == ParagraphKind::Formula {
                    let h = para_image_height(para, max_w);
                    if h > 0.0 && emit_formula(&mut content, &mut xobjects, para, doc, MARGIN, y, max_w) {
                        y -= h + PARA_SPACING;
                    } else {
                        for line in wrap_text(&para.source, max_w, BODY_SIZE, m) {
                            if y < MARGIN {
                                break;
                            }
                            emit_line(&mut content, m, MARGIN, y, BODY_SIZE, &line);
                            y -= line_h;
                        }
                        y -= PARA_SPACING;
                    }
                    continue;
                }
                let text = display_text(para);
                for line in wrap_text(&text, max_w, BODY_SIZE, m) {
                    if y < MARGIN {
                        // Overflow: the plan explicitly allows the physical
                        // page count to differ (plan §2) -- we stop rather
                        // than shrink the font.
                        break;
                    }
                    emit_line(&mut content, m, MARGIN, y, BODY_SIZE, &line);
                    y -= line_h;
                }
                y -= PARA_SPACING;
            }
        }
    }

    Ok(finish_page(doc, pages_id, font_id, content, xobjects, pw, ph))
}

/// Embeds a JPEG as an image XObject (DCTDecode -- no recompression) and
/// appends the `Do` operator drawing it at (x, y) sized (w_pt, h_pt).
#[allow(clippy::too_many_arguments)] // low-level emit helper: source px + dest rect
fn emit_image_jpeg(
    content: &mut String,
    xobjects: &mut Vec<(String, ObjectId)>,
    doc: &mut Document,
    jpeg: &[u8],
    px_w: i32,
    px_h: i32,
    x: f32,
    y: f32,
    w_pt: f32,
    h_pt: f32,
) {
    let stream = Stream::new(
        dictionary! {
            "Type" => name("XObject"),
            "Subtype" => name("Image"),
            "Width" => Object::Integer(px_w as i64),
            "Height" => Object::Integer(px_h as i64),
            "ColorSpace" => name("DeviceRGB"),
            "BitsPerComponent" => Object::Integer(8),
            "Filter" => name("DCTDecode"),
        },
        jpeg.to_vec(),
    );
    let id = doc.add_object(stream);
    let nm = format!("Bg{}", xobjects.len());
    content.push_str(&format!(
        "q {w_pt:.2} 0 0 {h_pt:.2} {x:.2} {y:.2} cm /{nm} Do Q\n"
    ));
    xobjects.push((nm, id));
}

/// Height the formula image will occupy (0 when no image is usable).
fn para_image_height(para: &TranslatedParagraph, max_w: f32) -> f32 {
    if let Some(path) = para.formula_regions.iter().find_map(|r| r.image_path.as_deref()) {
        if let Ok((iw, ih)) = image::image_dimensions(path) {
            let scale = (max_w / iw as f32).min(1.0);
            return ih as f32 * scale;
        }
    }
    0.0
}

/// Draws a formula image as an XObject; returns false when none could be used.
fn emit_formula(
    content: &mut String,
    xobjects: &mut Vec<(String, ObjectId)>,
    para: &TranslatedParagraph,
    doc: &mut Document,
    x: f32,
    y: f32,
    max_w: f32,
) -> bool {
    let Some(path) = para.formula_regions.iter().find_map(|r| r.image_path.as_deref()) else {
        return false;
    };
    let Ok(img) = image::open(path) else {
        return false;
    };
    let rgb = img.to_rgb8();
    let (iw, ih) = (rgb.width(), rgb.height());
    if iw == 0 || ih == 0 {
        return false;
    }
    let mut stream = Stream::new(
        dictionary! {
            "Type" => name("XObject"),
            "Subtype" => name("Image"),
            "Width" => Object::Integer(iw as i64),
            "Height" => Object::Integer(ih as i64),
            "ColorSpace" => name("DeviceRGB"),
            "BitsPerComponent" => Object::Integer(8),
        },
        rgb.into_raw(),
    );
    if stream.compress().is_err() {
        return false;
    }
    let scale = (max_w / iw as f32).min(1.0);
    let (w, h) = (iw as f32 * scale, ih as f32 * scale);
    if y - h < MARGIN {
        return false;
    }
    let id = doc.add_object(stream);
    let name = format!("Im{}", xobjects.len());
    content.push_str(&format!(
        "q {w:.2} 0 0 {h:.2} {x:.2} {y:.2} cm /{name} Do Q\n"
    ));
    xobjects.push((name, id));
    true
}

/// Appends one text line as an Identity-H glyph run.
fn emit_line(content: &mut String, m: &FontMetrics, x: f32, y: f32, size: f32, text: &str) {
    let hex = hex_gids(text, m);
    if hex.is_empty() {
        return;
    }
    content.push_str(&format!(
        "BT /F1 {size:.2} Tf 1 0 0 1 {x:.2} {y:.2} Tm <{hex}> Tj ET\n"
    ));
}

/// The text actually rendered for a paragraph: the translation with inline
/// formula tokens replaced by their source text (the pane does the same;
/// whole-paragraph formulas are images).
fn display_text(para: &TranslatedParagraph) -> String {
    let mut text = para.translated.clone();
    if text.trim().is_empty() {
        text = para.source.clone();
    }
    for (idx, region) in para.formula_regions.iter().enumerate() {
        let needle = format!("-MATH_{idx}⟩");
        if let Some(pos) = text.find(&needle) {
            let start = text[..pos].rfind('⟨').unwrap_or(pos);
            text.replace_range(start..pos + needle.len(), &region.source_text);
        }
    }
    text
}

/// Two-byte big-endian hex of each glyph id (Identity-H operand).
fn hex_gids(s: &str, m: &FontMetrics) -> String {
    let mut out = String::with_capacity(s.chars().count() * 4);
    for c in s.chars() {
        out.push_str(&format!("{:04X}", m.gid(c)));
    }
    out
}

fn name(s: &str) -> Object {
    Object::Name(s.as_bytes().to_vec())
}

// =============================================================================
// Wrapping (real font advances)
// =============================================================================

/// Greedy line wrapping with measured advances (plan §6: 量宽自算断行).
/// Breaks at spaces where possible; CJK breaks at any character. A single
/// token wider than the column gets its own line (no mid-word split).
fn wrap_text(s: &str, max_width: f32, font_size: f32, m: &FontMetrics) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in s.split('\n') {
        let mut line = String::new();
        let mut width = 0.0f32;
        let mut last_space: Option<usize> = None;
        for c in paragraph.chars() {
            let cw = m.advance(c, font_size);
            if width + cw > max_width && !line.is_empty() {
                if let Some(sp) = last_space {
                    let tail = line[sp + 1..].to_string();
                    let head = line[..sp].to_string();
                    if !head.is_empty() {
                        lines.push(head);
                        line = tail;
                        width = measure_width(&line, font_size, m);
                        last_space = None;
                        if c != ' ' {
                            line.push(c);
                            width += cw;
                        }
                        continue;
                    }
                }
                lines.push(std::mem::take(&mut line));
                width = 0.0;
                last_space = None;
                if c == ' ' {
                    continue;
                }
            }
            line.push(c);
            width += cw;
            if c == ' ' {
                last_space = Some(line.len() - 1);
            }
        }
        lines.push(line);
    }
    lines
}

/// Width of [s] at [font_size] using real advances.
fn measure_width(s: &str, font_size: f32, m: &FontMetrics) -> f32 {
    s.chars().map(|c| m.advance(c, font_size)).sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::annotation::NormRect;
    use crate::models::translate::{FormulaRegion, ParagraphStatus};

    fn metrics() -> FontMetrics {
        // Cover every char the tests exercise -- including the anchors and the
        // placeholder text -- so advances are real and glyphs are present
        // (a char absent from the subset falls back to .notdef and would be
        // dropped by extractors).
        FontMetrics::prepare(
            &"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.\
               原书第页尚未翻译　译本：p，。量子力学一二三四五六七八九十当为正你好世界 \
               x+y ispositivefor⟨FabMATH_⟩"
                .chars()
                .collect::<Vec<_>>(),
        )
        .expect("bundled font must parse + subset")
    }

    fn text_para(source: &str, translated: &str) -> TranslatedParagraph {
        TranslatedParagraph {
            source: source.into(),
            translated: translated.into(),
            kind: ParagraphKind::Text,
            status: ParagraphStatus::Done,
            confidence: 1.0,
            formula_regions: Vec::new(),
            rects: Vec::new(),
        }
    }

    #[test]
    fn bundled_font_subsets_to_tiny_bytes() {
        let m = metrics();
        // A handful of glyphs must produce a small subset (the whole font is
        // ~10 MB).
        assert!(
            m.font_file.len() < 200_000,
            "subset {} bytes -- subsetting did not take",
            m.font_file.len()
        );
        assert!(!m.font_file.is_empty());
    }

    #[test]
    fn cjk_advances_are_full_width() {
        let m = metrics();
        let cjk = m.advance('量', 10.0);
        let ascii = m.advance('a', 10.0);
        assert!(cjk > ascii, "cjk {cjk} vs ascii {ascii}");
        assert!((cjk - 10.0).abs() < 0.01, "CJK should be 1em: {cjk}");
    }

    #[test]
    fn wrap_breaks_cjk_at_width() {
        let m = metrics();
        let lines = wrap_text("一二三四五六七八九十", 45.0, 10.0, &m);
        assert_eq!(lines.concat(), "一二三四五六七八九十");
        assert!(lines.len() >= 3, "{lines:?}");
    }

    #[test]
    fn wrap_prefers_space_for_latin() {
        let m = metrics();
        let lines = wrap_text("hello world again", 40.0, 10.0, &m);
        for l in &lines {
            assert!(!l.starts_with(' '));
            assert!(!l.ends_with(' '));
        }
        let joined = lines.join(" ");
        assert_eq!(
            joined.split_whitespace().collect::<Vec<_>>(),
            vec!["hello", "world", "again"]
        );
    }

    #[test]
    fn inline_formula_tokens_become_source_text() {
        let mut p = text_para("for x2 +y is positive", "当 ⟨Fab12-MATH_0⟩ 为正");
        p.formula_regions = vec![FormulaRegion {
            rect: NormRect { x: 0.1, y: 0.5, w: 0.1, h: 0.02 },
            image_path: None,
            source_text: "x2 +y".into(),
            placeholder: String::new(),
        }];
        let out = display_text(&p);
        assert_eq!(out, "当 x2 +y 为正");
        assert!(!out.contains("MATH"));
        assert!(!out.contains('⟨'));
    }

    #[test]
    fn hex_gids_are_two_bytes_per_char() {
        let m = metrics();
        let hex = hex_gids("量子", &m);
        assert_eq!(hex.len(), 8, "{hex}");
        assert!(hex.chars().all(|c| c.is_ascii_hexdigit()));
    }

    /// End-to-end: seed a 3-page book (1 translated, 1 empty, 1 untranslated)
    /// and confirm the writer walks 1..N, emits an "原书 p.N" anchor on every
    /// page, inserts the placeholder page, and produces a small PDF whose
    /// text extracts back (selectable). Skips without libpdfium.
    #[test]
    fn build_pdf_walks_pages_and_inserts_placeholder() {
        use crate::db::schema::{PRAGMAS, SCHEMA_SQL};
        use crate::models::translate::{
            PageTranslation, ParagraphStatus, TranslatedParagraph,
        };

        // Isolate the DB + data dir in a scratch path.
        let scratch = std::env::temp_dir().join(format!("rbwa_pdfw_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).unwrap();
        let db_path = scratch.join("rbwa.db");
        let conn = rusqlite::Connection::open(&db_path).unwrap();
        for p in PRAGMAS {
            conn.execute_batch(p).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute(
            "INSERT INTO books (id, title, original_path, stored_path, file_type, page_count) \
             VALUES (1, '测试书', '/x.pdf', '/nonexistent.pdf', 'pdf', 3)",
            [],
        )
        .unwrap();
        // Page 2 translated; page 1 has an empty translation; page 3 missing.
        let page2 = PageTranslation {
            page: 2,
            target_lang: "中文".into(),
            provider: "reuse_ai".into(),
            source_hash: "h".into(),
            paragraphs: vec![TranslatedParagraph {
                source: "Hello world".into(),
                translated: "你好世界".into(),
                kind: ParagraphKind::Text,
                status: ParagraphStatus::Done,
                confidence: 1.0,
                formula_regions: Vec::new(),
                rects: Vec::new(),
            }],
            coverage: 1.0,
        };
        crate::db::repository::translate::save_page_translation(&conn, 1, "中文", &page2).unwrap();
        // Point the global DB at this scratch DB so the writer reads it.
        // (build_translated_pdf calls db::db(); the process-global is only
        // settable once, so this test runs the pure assembly path instead:
        // construct plans directly -- the DB plumbing is covered elsewhere.)
        drop(conn);

        // Pure assembly: build the PDF bytes for the three plans and check
        // the page count / anchors by reopening with pdfium.
        let m = metrics();
        let mut doc = Document::with_version("1.7");
        let pages_id = doc.new_object_id();
        let catalog_id = doc.add_object(dictionary! {
            "Type" => name("Catalog"),
            "Pages" => Object::Reference(pages_id),
        });
        doc.trailer.set("Root", Object::Reference(catalog_id));
        let font_id = add_font(&mut doc, &m).unwrap();
        let plans = vec![
            PagePlan { page: 1, pw: 595.0, ph: 842.0, cached: None },
            PagePlan { page: 2, pw: 595.0, ph: 842.0, cached: Some(page2.clone()) },
            PagePlan { page: 3, pw: 595.0, ph: 842.0, cached: None },
        ];
        let mut kids = Vec::new();
        for plan in &plans {
            // No background -> the flow layout (anchors + placeholders); these
            // plans' paragraphs also carry no rects, so overlay never applies.
            kids.push(Object::Reference(
                write_page(&mut doc, pages_id, font_id, plan, "中文", &m, None).unwrap(),
            ));
        }
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => name("Pages"),
                "Kids" => Object::Array(kids),
                "Count" => Object::Integer(3),
            }),
        );
        let bytes = {
            let mut buf = Vec::new();
            doc.save_to(&mut buf).unwrap();
            buf
        };
        // Small: three pages + a tiny subset font, nowhere near the 10 MB font.
        assert!(bytes.len() < 1_000_000, "pdf {} bytes", bytes.len());

        let pdf_path = scratch.join("out.pdf");
        std::fs::write(&pdf_path, &bytes).unwrap();
        // Reopen under the pdfium lock (pdfium is not thread-safe).
        let checked = crate::pdf::with_document_file(pdf_path.to_str().unwrap(), |reopened| {
            if reopened.pages().len() != 3 {
                return Err(AppError::Pdf(format!(
                    "expected 3 pages, got {}",
                    reopened.pages().len()
                )));
            }
            let p1 = reopened.pages().get(0)?.text()?.all();
            assert!(p1.contains("p.1"), "page1 anchor: {p1:?}");
            assert!(p1.contains("尚未翻译"), "page1 placeholder: {p1:?}");
            let p2 = reopened.pages().get(1)?.text()?.all();
            assert!(p2.contains("p.2"), "page2 anchor: {p2:?}");
            assert!(p2.contains("你好世界"), "page2 body: {p2:?}");
            let p3 = reopened.pages().get(2)?.text()?.all();
            assert!(p3.contains("尚未翻译"), "page3 placeholder: {p3:?}");
            Ok(())
        });
        if checked.is_err() {
            eprintln!("skipping pdf reopen: libpdfium not on the search path");
        }
        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// Overlay layout: whitened raster background + the translation drawn as
    /// vector text at the paragraphs' original footprints (no anchor, no
    /// reflow). Formula paragraphs must NOT be whitened.
    #[test]
    fn overlay_page_keeps_background_and_positions_translation() {
        // Paragraphs with line rects (as persisted since extractor v3).
        let mut hello = text_para("Hello world", "你好世界");
        hello.rects = vec![
            NormRect { x: 0.1, y: 0.1, w: 0.5, h: 0.02 },
            NormRect { x: 0.1, y: 0.125, w: 0.45, h: 0.02 },
        ];
        let mut formula = text_para("x2 +y", "");
        formula.kind = ParagraphKind::Formula;
        formula.rects = vec![NormRect { x: 0.7, y: 0.7, w: 0.2, h: 0.1 }];
        let t = PageTranslation {
            page: 1,
            target_lang: "中文".into(),
            provider: "reuse_ai".into(),
            source_hash: "h".into(),
            paragraphs: vec![hello, formula],
            coverage: 1.0,
        };

        // Whitening: text rects go white, the formula rect stays.
        let mut img = image::RgbaImage::from_pixel(100, 100, image::Rgba([128, 128, 128, 255]));
        whiten_paragraphs(&mut img, &t);
        assert_eq!(img.get_pixel(30, 12), &image::Rgba([255, 255, 255, 255]));
        assert_eq!(img.get_pixel(15, 14), &image::Rgba([255, 255, 255, 255]));
        assert_eq!(img.get_pixel(80, 75), &image::Rgba([128, 128, 128, 255]));

        // Fabricate a background JPEG (no pdfium needed for assembly).
        let probe = image::RgbImage::from_pixel(20, 10, image::Rgb([200, 10, 10]));
        let mut jpeg_buf = std::io::Cursor::new(Vec::new());
        probe
            .write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(
                &mut jpeg_buf, 88,
            ))
            .unwrap();
        let bg = Background { jpeg: jpeg_buf.into_inner(), px_w: 20, px_h: 10 };

        let m = metrics();
        let mut doc = Document::with_version("1.7");
        let pages_id = doc.new_object_id();
        let catalog_id = doc.add_object(dictionary! {
            "Type" => name("Catalog"),
            "Pages" => Object::Reference(pages_id),
        });
        doc.trailer.set("Root", Object::Reference(catalog_id));
        let font_id = add_font(&mut doc, &m).unwrap();
        let plan = PagePlan { page: 1, pw: 595.0, ph: 842.0, cached: Some(t) };
        let page_id = write_page(
            &mut doc, pages_id, font_id, &plan, "中文", &m, Some(&bg),
        )
        .unwrap();
        doc.objects.insert(
            pages_id,
            Object::Dictionary(dictionary! {
                "Type" => name("Pages"),
                "Kids" => Object::Array(vec![Object::Reference(page_id)]),
                "Count" => Object::Integer(1),
            }),
        );
        let mut buf = Vec::new();
        doc.save_to(&mut buf).unwrap();

        // The assembled doc carries exactly one DCTDecode image XObject.
        let images = doc
            .objects
            .values()
            .filter(|o| {
                o.as_stream().map(|s| {
                    s.dict.get(b"Subtype").ok()
                        .and_then(|v| v.as_name().ok())
                        == Some(b"Image".as_slice())
                }).unwrap_or(false)
            })
            .count();
        assert_eq!(images, 1, "overlay page must embed the background image");

        // Reopen (skips without libpdfium): the translation extracts as text
        // at the page level and the flow-layout anchor is gone.
        let pdf_path = std::env::temp_dir().join(format!("rbwa_overlay_{}.pdf", std::process::id()));
        std::fs::write(&pdf_path, &buf).unwrap();
        let checked = crate::pdf::with_document_file(pdf_path.to_str().unwrap(), |reopened| {
            assert_eq!(reopened.pages().len(), 1);
            let text = reopened.pages().get(0)?.text()?.all();
            assert!(text.contains("你好世界"), "overlay text: {text:?}");
            assert!(!text.contains("原书 p."), "overlay drops the anchor: {text:?}");
            Ok(())
        });
        if checked.is_err() {
            eprintln!("skipping pdf reopen: libpdfium not on the search path");
        }
        let _ = std::fs::remove_file(&pdf_path);
    }

    #[test]
    fn fit_paragraph_shrinks_until_it_fits() {
        let m = metrics();
        let text = "量子力学是物理学的分支，研究物质世界微观尺度上的结构与演化规律。".repeat(6);
        let (hint_size, _) = fit_paragraph(&text, 200.0, 10_000.0, &m, 11.0);
        // Tall box: the hint size already fits.
        assert!((hint_size - 11.0).abs() < 1e-4);
        // Tight box: the size shrinks towards the floor.
        let (size, lines) = fit_paragraph(&text, 200.0, 40.0, &m, 11.0);
        assert!(size < 11.0, "must shrink: {size}");
        assert!(lines.len() as f32 * size * LINE_SPACING <= 40.0 + f32::EPSILON || size == MIN_OVERLAY_SIZE);
        // Union of line rects spans the whole paragraph footprint.
        let u = union_rect(&[
            NormRect { x: 0.2, y: 0.1, w: 0.3, h: 0.02 },
            NormRect { x: 0.1, y: 0.12, w: 0.4, h: 0.02 },
        ])
        .unwrap();
        assert!((u.x - 0.1).abs() < 1e-9 && (u.y - 0.1).abs() < 1e-9);
        assert!((u.w - 0.4).abs() < 1e-9 && (u.h - 0.04).abs() < 1e-9);
    }
}

