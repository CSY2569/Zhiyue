//! Real OCR engine: PP-OCRv4 (det / cls / rec) via rapidocr-core on ONNX
//! Runtime (FEATURES §7.1). Models are provisioned by
//! `scripts/download_ocr_models.sh` into `{data_dir}/models/`:
//!
//! ```text
//! models/
//!   cls.onnx               # ch_ppocr_mobile_v2.0_cls_mobile.onnx (shared)
//!   ppocr_keys_v1.txt      # recognition dictionary (shared)
//!   high_precision/        # ch_PP-OCRv4_*_server.onnx (7.1.9)
//!     det.onnx
//!     rec.onnx
//!   fast/                  # ch_PP-OCRv4_*_mobile.onnx (7.1.9)
//!     det.onnx
//!     rec.onnx
//! ```
//!
//! The engine lazy-loads on the first scan (7.1.5): `OnceLock` per mode,
//! sessions are created once and reused. Inference runs on the calling
//! thread (a FRB async worker, off the UI isolate), serialized per mode via
//! a mutex because ONNX Runtime sessions execute statefully.

use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use image::RgbImage;
use rapidocr_core::config::{
    ClsConfig, DetConfig, DetInputLimits, InferenceOptions, LimitType, PipelineConfig,
    RapidOcrConfig, RecConfig,
};
use rapidocr_core::RapidOcr;

use crate::db;
use crate::error::{AppError, AppResult};
use crate::ocr::{OcrEngine, OcrLine, OcrResult, PageImage, StubOcrEngine};

/// Model directory layout: shared classifier + dictionary at the root,
/// per-mode det/rec below `{mode}/`.
const CLS_FILE: &str = "cls.onnx";
const DICT_FILE: &str = "ppocr_keys_v1.txt";
const DET_FILE: &str = "det.onnx";
const REC_FILE: &str = "rec.onnx";

/// PaddleOCR preprocessing constants for PP-OCRv4 (same values the official
/// pipeline uses).
const DET_MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const DET_STD: [f32; 3] = [0.229, 0.224, 0.225];
/// Detector input side limit (PP-OCRv4 expects the longest side <= 960).
const DET_LIMIT_SIDE: u32 = 960;
/// Classifier input shape [C, H, W].
const CLS_SHAPE: [usize; 3] = [3, 48, 192];
/// Recognition input shape [C, H, W] (PP-OCRv4 rec height is 48, width is
/// padded dynamically up to this maximum).
const REC_SHAPE: [usize; 3] = [3, 48, 320];

/// The real OCR engine (zero-sized; all state lives in the per-mode
/// [OnceLock] slots so the engine lazy-loads on first use).
pub(crate) struct RapidOcrEngine;

type LoadResult = Result<Mutex<RapidOcr>, String>;

static ENGINES: [OnceLock<LoadResult>; 2] = [OnceLock::new(), OnceLock::new()];

impl RapidOcrEngine {
    /// Slot index per mode ("high_precision" = 0, "fast" = 1).
    fn slot(mode: &str) -> usize {
        if mode == "fast" { 1 } else { 0 }
    }

    /// The four model files for [mode]; shared cls/dict live at the models
    /// root. Returns `None` when any file is missing (models not installed).
    fn model_files(mode: &str) -> Option<(PathBuf, PathBuf, PathBuf, PathBuf)> {
        let root = db::app_data_dir().ok()?.join("models");
        let dir = root.join(mode);
        let det = dir.join(DET_FILE);
        let rec = dir.join(REC_FILE);
        let cls = root.join(CLS_FILE);
        let dict = root.join(DICT_FILE);
        for f in [&det, &rec, &cls, &dict] {
            if !f.is_file() {
                return None;
            }
        }
        Some((det, rec, cls, dict))
    }

    /// Build the rapidocr pipeline for [mode], loading the ONNX sessions
    /// (runs once per mode; 7.1.5 lazy loading).
    fn load(mode: &str) -> LoadResult {
        let (det_path, rec_path, cls_path, dict_path) =
            Self::model_files(mode).ok_or_else(|| StubOcrEngine::MISSING_MODELS.to_string())?;
        let cfg = RapidOcrConfig {
            pipeline: PipelineConfig::full(),
            inference: InferenceOptions {
                intra_threads: 4,
                ..InferenceOptions::default()
            },
            text_score: 0.5,
            min_side_len: 30,
            max_side_len: 2000,
            min_height: 30,
            width_height_ratio: -1.0, // no vertical-padding gate for pages
            det: Some(DetConfig {
                model_path: det_path,
                limit_side_len: DET_LIMIT_SIDE,
                limit_type: LimitType::Max,
                input_limits: DetInputLimits::default(),
                mean: DET_MEAN,
                std: DET_STD,
                thresh: 0.3,
                box_thresh: 0.6,
                max_candidates: 1000,
                unclip_ratio: 1.5,
                min_size: 3,
            }),
            cls: Some(ClsConfig {
                model_path: cls_path,
                image_shape: CLS_SHAPE,
                batch_size: 6,
                thresh: 0.9,
                labels: vec!["0".to_string(), "180".to_string()],
            }),
            rec: Some(RecConfig {
                model_path: rec_path,
                dict_path,
                image_shape: REC_SHAPE,
                batch_size: 6,
            }),
        };
        RapidOcr::new(cfg)
            .map(Mutex::new)
            .map_err(|e| format!("{e:#}"))
    }

    /// One scan run under the mode's engine lock.
    fn run(image: &PageImage<'_>, mode: &str) -> AppResult<OcrResult> {
        // Pure CPU conversion -- touches no engine state, so do it outside
        // the mode lock: a multi-MB RGBA→RGB conversion must not block scans
        // of the other mode.
        let rgb = RgbImage::from_raw(
            image.width,
            image.height,
            to_rgb(image.rgba),
        )
        .ok_or_else(|| AppError::Ocr("页面图像数据无效".into()))?;
        // 7.1.10: adaptive page-quality enhancement (no-op on clean pages).
        let enhanced = enhance(&rgb);

        let slot = &ENGINES[Self::slot(mode)];
        let loaded = slot.get_or_init(|| Self::load(mode));
        let mut engine = loaded
            .as_ref()
            .map_err(|e| AppError::Ocr(e.clone()))?
            .lock()
            .map_err(|_| AppError::Ocr("OCR 引擎内部错误（锁中毒）".into()))?;

        // 7.1.12: page-orientation handling -- 180° is corrected inside the
        // pipeline (cls), 90° via a suspicious-result re-scan below. The
        // winning pass's quads are mapped back to source coordinates.
        let (lines, rot) = scan_orientation(&mut engine, &enhanced)?;

        let w = f64::from(image.width);
        let h = f64::from(image.height);
        let lines = lines
            .into_iter()
            .map(|l| normalize(l, w, h, rot))
            .collect();
        Ok(OcrResult { lines, mode: mode.to_string() })
    }
}

impl OcrEngine for RapidOcrEngine {
    fn is_available(&self) -> bool {
        Self::model_files("high_precision").is_some()
            || Self::model_files("fast").is_some()
    }

    fn scan(&self, image: &PageImage<'_>, mode: &str) -> AppResult<OcrResult> {
        Self::run(image, mode)
    }
}

/// Page rotation applied by a scan pass (7.1.12 orientation handling).
#[derive(Debug, Clone, Copy, PartialEq)]
enum PageRotation {
    /// No rotation (the first pass; the common case).
    None,
    /// 90° clockwise (image::imageops::rotate90).
    Clockwise90,
    /// 90° counter-clockwise (image::imageops::rotate270).
    Counterclockwise90,
}

/// Map a quad from a rotated pass back into the source image coordinates.
/// rotate90 (clockwise): source (x, y) -> dest (h-1-y, x), so the inverse
/// is (x', y') -> (y', h-1-x'); rotate270 inverts to (x', y') ->
/// (w-1-y', x'). Unit-tested with a round-trip.
fn map_quad_back(
    pts: [[f32; 2]; 4],
    src_w: f32,
    src_h: f32,
    rot: PageRotation,
) -> [[f32; 2]; 4] {
    match rot {
        PageRotation::None => pts,
        PageRotation::Clockwise90 => pts.map(|[x, y]| [y, src_h - 1.0 - x]),
        PageRotation::Counterclockwise90 => pts.map(|[x, y]| [src_w - 1.0 - y, x]),
    }
}

/// One full pipeline pass (det -> cls -> rec). Returns the raw lines in the
/// coordinates of [img] (which may be a rotated copy).
fn scan_pass(
    engine: &mut RapidOcr,
    img: &RgbImage,
) -> AppResult<Vec<rapidocr_core::types::OcrLine>> {
    let out = engine
        .run_image(img)
        .map_err(|e| AppError::Ocr(format!("{e:#}")))?;
    Ok(out.lines)
}

/// Total recognition confidence of a pass (used to pick the orientation).
fn pass_score(lines: &[rapidocr_core::types::OcrLine]) -> f64 {
    lines.iter().map(|l| f64::from(l.score)).sum()
}

/// Whether the first pass looks like a rotated page: text WAS detected but
/// few lines / low confidence (a blank page stays blank when rotated, so
/// retrying it would only waste two passes).
fn suspicious(lines: &[rapidocr_core::types::OcrLine]) -> bool {
    if lines.is_empty() {
        return false;
    }
    lines.len() < 3 || pass_score(lines) / (lines.len() as f64) < 0.6
}

/// Run the pipeline, re-scanning rotated copies when the first pass looks
/// suspicious (7.1.12): a sideways page yields few / low-confidence lines,
/// so try 90° and 270° and keep the best-scoring pass -- with a 10% margin
/// so a legitimate sparse page is never replaced by a wrong rotation. The
/// winning pass's quads are mapped back to the source image coordinates.
/// Cost: zero extra passes on normal pages; at most two extra on sideways /
/// low-quality pages.
fn scan_orientation(
    engine: &mut RapidOcr,
    rgb: &RgbImage,
) -> AppResult<(Vec<rapidocr_core::types::OcrLine>, PageRotation)> {
    let first = scan_pass(engine, rgb)?;
    if !suspicious(&first) {
        return Ok((first, PageRotation::None));
    }
    let cw_img = image::imageops::rotate90(rgb);
    let ccw_img = image::imageops::rotate270(rgb);
    let cw = scan_pass(engine, &cw_img)?;
    let ccw = scan_pass(engine, &ccw_img)?;

    let mut best: (f64, PageRotation, Vec<rapidocr_core::types::OcrLine>) =
        (pass_score(&first), PageRotation::None, first);
    for (rot, lines) in [
        (PageRotation::Clockwise90, cw),
        (PageRotation::Counterclockwise90, ccw),
    ] {
        let s = pass_score(&lines);
        if s > best.0 * 1.1 {
            best = (s, rot, lines);
        }
    }
    Ok((best.2, best.1))
}

/// Adaptive page-quality enhancement before detection (7.1.10): washed-out
/// pages get a percentile contrast stretch, blurry pages get sharpened.
/// Every branch is gated by density-independent statistics (ink luminance /
/// sharp-edge fraction), so clean pages -- however sparse the text -- are
/// returned pixel-identical.
fn enhance(img: &RgbImage) -> RgbImage {
    // A healthy scan has dark ink (median luma well below 80) and sharp
    // edges (a measurable share of samples with |gradient| > 120). A
    // washed-out scan's ink is gray; a blurry scan's edges are soft.
    const WASHED_INK_MIN: f64 = 80.0; // ink brighter than this = washed out
    const WASHED_SPAN_MIN: f64 = 30.0; // stretchable ink/background range
    const SHARP_EDGE_FRAC: f64 = 1e-4; // below this the page is blurry

    let q = page_quality(img);
    let mut out = img.clone();
    if q.ink_frac > 0.0 && q.ink_median > WASHED_INK_MIN && q.p99 - q.ink_median > WASHED_SPAN_MIN {
        stretch_contrast(&mut out, q.ink_median, q.p99);
    }
    if q.ink_frac > 0.0 && sharp_edge_fraction(&out) < SHARP_EDGE_FRAC {
        // Denoise + sharpen in one pass (unsharpen = blur difference).
        out = image::imageops::unsharpen(&out, 2.0, 0);
    }
    out
}

/// Density-independent page statistics from one 4x4-sampled pass. Percentile
/// of ALL pixels is useless on sparse pages (1% of a text page is pure
/// background), so ink quality is measured only over ink pixels (luma < 200):
/// [ink_median] answers "is the ink itself gray?".
#[derive(Debug)]
struct PageQuality {
    /// 99th percentile of all sampled luma (the background end).
    p99: f64,
    /// Median luma over ink pixels (luma < 200).
    ink_median: f64,
    /// Fraction of sampled pixels that are ink (text presence).
    ink_frac: f64,
}

fn page_quality(img: &RgbImage) -> PageQuality {
    let mut luma_values: Vec<f64> = Vec::with_capacity(140_000);
    let mut ink_values: Vec<f64> = Vec::with_capacity(140_000);
    let mut n = 0.0f64;
    for px in sampled_pixels(img) {
        let l = luma(px);
        luma_values.push(l);
        if l < 200.0 {
            ink_values.push(l);
        }
        n += 1.0;
    }
    let p99 = percentile(&luma_values, 0.99).unwrap_or(255.0);
    let ink_median = percentile(&ink_values, 0.5).unwrap_or(255.0);
    let ink_frac = ink_values.len() as f64 / n.max(1.0);
    PageQuality { p99, ink_median, ink_frac }
}

/// Fraction of sampled pixels with a strong horizontal or vertical gradient
/// (|dx|+|dy| > 120). Sharp text edges qualify; soft (blurry / interpolated)
/// edges do not -- so the fraction collapses on blurry pages regardless of
/// how much text they carry.
fn sharp_edge_fraction(img: &RgbImage) -> f64 {
    let w = img.width() as i64;
    let h = img.height() as i64;
    let mut strong = 0.0f64;
    let mut n = 0.0f64;
    for y in (1..h - 1).step_by(4) {
        for x in (1..w - 1).step_by(4) {
            let c = luma(img.get_pixel(x as u32, y as u32).0);
            let dx = luma(img.get_pixel((x + 1) as u32, y as u32).0) - c;
            let dy = luma(img.get_pixel(x as u32, (y + 1) as u32).0) - c;
            if dx.abs() + dy.abs() > 120.0 {
                strong += 1.0;
            }
            n += 1.0;
        }
    }
    if n == 0.0 {
        return 0.0;
    }
    strong / n
}

/// Quantile of a sorted-able luma sample set; `None` when empty.
fn percentile(values: &[f64], q: f64) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut v: Vec<f64> = values.to_vec();
    v.sort_unstable_by(|a, b| a.total_cmp(b));
    Some(v[((v.len() as f64) * q) as usize])
}

/// Linear stretch mapping [lo, hi] onto [0, 255] in place (robust contrast
/// enhancement: the lo/hi anchors come from ink / background percentiles).
fn stretch_contrast(img: &mut RgbImage, lo: f64, hi: f64) {
    let range = (hi - lo).max(1.0);
    for px in img.pixels_mut() {
        for c in px.0.iter_mut() {
            let v = (f64::from(*c) - lo) / range * 255.0;
            *c = v.round().clamp(0.0, 255.0) as u8;
        }
    }
}

/// Luma of an RGB pixel (ITU-R BT.601 weights).
fn luma(px: [u8; 3]) -> f64 {
    f64::from(px[0]) * 0.299 + f64::from(px[1]) * 0.587 + f64::from(px[2]) * 0.114
}

/// Every 4th pixel in row-major order (the sampling grid shared by the
/// enhancement statistics).
fn sampled_pixels(img: &RgbImage) -> impl Iterator<Item = [u8; 3]> + '_ {
    (0..img.height())
        .step_by(4)
        .flat_map(move |y| (0..img.width()).step_by(4).map(move |x| img.get_pixel(x, y).0))
}

/// RGBA bytes (page rendering format) -> RGB bytes (rapidocr input).
fn to_rgb(rgba: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
    for px in rgba.chunks_exact(4) {
        rgb.push(px[0]);
        rgb.push(px[1]);
        rgb.push(px[2]);
    }
    rgb
}

/// Rapidocr output box (source-image pixel coordinates, top-left origin) ->
/// the normalized line rect of the OCR contract (Flutter space). Quads from
/// a rotated pass are mapped back to the source image first.
fn normalize(
    line: rapidocr_core::types::OcrLine,
    w: f64,
    h: f64,
    rot: PageRotation,
) -> OcrLine {
    let pts = map_quad_back(line.bbox.points, w as f32, h as f32, rot);
    let min_x = pts.iter().map(|p| f64::from(p[0])).fold(f64::INFINITY, f64::min);
    let max_x = pts.iter().map(|p| f64::from(p[0])).fold(f64::NEG_INFINITY, f64::max);
    let min_y = pts.iter().map(|p| f64::from(p[1])).fold(f64::INFINITY, f64::min);
    let max_y = pts.iter().map(|p| f64::from(p[1])).fold(f64::NEG_INFINITY, f64::max);
    OcrLine {
        text: line.text,
        x: (min_x / w).clamp(0.0, 1.0),
        y: (min_y / h).clamp(0.0, 1.0),
        // +1: the quad coordinates are inclusive pixel bounds.
        w: ((max_x - min_x + 1.0) / w).clamp(0.0, 1.0),
        h: ((max_y - min_y + 1.0) / h).clamp(0.0, 1.0),
        confidence: f64::from(line.score),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ab_glyph::{FontRef, PxScale};
    use image::Rgb;
    use imageproc::drawing::draw_text_mut;

    #[test]
    fn rgba_to_rgb_drops_alpha() {
        let rgba = [10, 20, 30, 255, 40, 50, 60, 0];
        assert_eq!(to_rgb(&rgba), vec![10, 20, 30, 40, 50, 60]);
    }

    #[test]
    fn normalize_converts_pixel_box_to_unit_rect() {
        let line = rapidocr_core::types::OcrLine {
            bbox: rapidocr_core::types::Quad {
                points: [[100.0, 50.0], [200.0, 50.0], [200.0, 60.0], [100.0, 60.0]],
            },
            text: "你好".into(),
            score: 0.93,
        };
        let n = normalize(line, 1000.0, 500.0, PageRotation::None);
        assert_eq!(n.x, 0.1);
        assert_eq!(n.y, 0.1);
        assert!((n.w - 0.101).abs() < 1e-9); // 101 / 1000 (inclusive bounds)
        assert!((n.h - 0.022).abs() < 1e-9); // 11 / 500
        assert_eq!(n.text, "你好");
        // f32 -> f64 widening carries ~1e-8 rounding from the model score.
        assert!((n.confidence - 0.93).abs() < 1e-6);
    }

    #[test]
    fn normalize_clamps_out_of_bounds() {
        let line = rapidocr_core::types::OcrLine {
            bbox: rapidocr_core::types::Quad {
                points: [[-5.0, -3.0], [10.0, -3.0], [10.0, 2.0], [-5.0, 2.0]],
            },
            text: "x".into(),
            score: 0.5,
        };
        let n = normalize(line, 100.0, 100.0, PageRotation::None);
        assert_eq!(n.x, 0.0);
        assert_eq!(n.y, 0.0);
        assert_eq!(n.w, 0.16); // 16 / 100
    }

    #[test]
    fn map_quad_back_roundtrips_rotations() {
        // Source quad; rotate the image both ways, then map the rotated
        // coordinates back -- identity within f32 precision.
        let pts = [[10.0, 20.0], [110.0, 20.0], [110.0, 30.0], [10.0, 30.0]];
        let (w, h) = (100.0f32, 200.0f32);

        // Clockwise (rotate90): dest (x', y') = (h-1-y, x).
        let rotated = pts.map(|[x, y]| [h - 1.0 - y, x]);
        let back = map_quad_back(rotated, w, h, PageRotation::Clockwise90);
        for (a, b) in back.iter().zip(pts.iter()) {
            assert!((a[0] - b[0]).abs() < 1e-4 && (a[1] - b[1]).abs() < 1e-4, "{back:?}");
        }

        // Counter-clockwise (rotate270): dest (x', y') = (y, w-1-x).
        let rotated = pts.map(|[x, y]| [y, w - 1.0 - x]);
        let back = map_quad_back(rotated, w, h, PageRotation::Counterclockwise90);
        for (a, b) in back.iter().zip(pts.iter()) {
            assert!((a[0] - b[0]).abs() < 1e-4 && (a[1] - b[1]).abs() < 1e-4, "{back:?}");
        }

        // None is a passthrough.
        assert_eq!(map_quad_back(pts, w, h, PageRotation::None), pts);
    }

    #[test]
    fn suspicious_flags_few_or_low_confidence_lines_only() {
        let line = |score: f32| rapidocr_core::types::OcrLine {
            bbox: rapidocr_core::types::Quad {
                points: [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0]],
            },
            text: "x".into(),
            score,
        };
        // Empty (blank page) and healthy results must NOT retry.
        assert!(!suspicious(&[]));
        assert!(!suspicious(&[line(0.9), line(0.9), line(0.9)]));
        // Few lines or low average confidence -> suspicious (sideways page).
        assert!(suspicious(&[line(0.9), line(0.9)]));
        assert!(suspicious(&[line(0.4), line(0.4), line(0.4)]));
    }

    #[test]
    fn enhance_stretches_low_contrast_and_spares_clean_pages() {
        // Washed-out page: 150-gray ink on 245-gray paper. The ink median
        // (150) clears the washed-out gate, so the stretch must fire.
        let mut low = RgbImage::from_pixel(64, 64, image::Rgb([245, 245, 245]));
        for x in 0..64 {
            low.put_pixel(x, 32, image::Rgb([150, 150, 150]));
        }
        let q = page_quality(&low);
        assert!(q.ink_median > 80.0 && q.p99 - q.ink_median > 30.0, "gate: {q:?}");
        let enhanced = enhance(&low);
        // Stretch maps 150 -> 0 and 245 -> 255: the ink is now dark.
        assert_eq!(enhanced.get_pixel(0, 32).0, [0, 0, 0], "ink must be stretched to black");
        assert_eq!(enhanced.get_pixel(0, 0).0, [255, 255, 255], "paper to white");

        // Clean high-contrast page: enhance must not touch it.
        let mut clean = RgbImage::from_pixel(64, 64, image::Rgb([255, 255, 255]));
        for x in 0..64 {
            clean.put_pixel(x, 32, image::Rgb([0, 0, 0]));
        }
        let enhanced = enhance(&clean);
        assert_eq!(enhanced, clean, "clean pages must be pixel-identical");
    }

    #[test]
    fn enhance_sharpens_blurry_pages() {
        // Gaussian blur softens every edge: the sharp-edge fraction drops
        // below the gate and the unsharpen branch must fire (a mild blur is
        // recoverable; a heavy one would leave the page unchanged).
        let mut clean = RgbImage::from_pixel(128, 128, image::Rgb([255, 255, 255]));
        for x in 0..128 {
            clean.put_pixel(x, 64, image::Rgb([0, 0, 0]));
        }
        let blurred = image::imageops::blur(&clean, 1.5);
        assert!(
            sharp_edge_fraction(&blurred) < 1e-4,
            "blur must soften edges, got {}",
            sharp_edge_fraction(&blurred)
        );
        let enhanced = enhance(&blurred);
        assert_ne!(enhanced, blurred, "unsharpen must fire on blurry pages");
        // Sharpness = the steepest single-pixel gradient. Unsharp masking
        // steepens edges, so the peak gradient must rise.
        let max_gradient = |img: &RgbImage| {
            let mut max = 0.0f64;
            for y in 0..img.height() - 1 {
                for x in 0..img.width() - 1 {
                    let c = luma(img.get_pixel(x, y).0);
                    let dx = (luma(img.get_pixel(x + 1, y).0) - c).abs();
                    let dy = (luma(img.get_pixel(x, y + 1).0) - c).abs();
                    max = max.max(dx).max(dy);
                }
            }
            max
        };
        let before = max_gradient(&blurred);
        let after = max_gradient(&enhanced);
        assert!(
            after > before * 1.1,
            "unsharpen must steepen edges: {before:.1} -> {after:.1}"
        );
    }

    #[test]
    fn model_files_detects_absence() {
        // An unknown mode can never have models installed.
        assert!(RapidOcrEngine::model_files("nonexistent-mode").is_none());
    }

    // --- End-to-end helpers (require downloaded models; see below) --------

    /// Load the system DejaVu font used by all synthetic pages. Box::leak
    /// gives the FontRef a 'static lifetime (test-only; ~700KB per call).
    fn test_font() -> FontRef<'static> {
        let data = std::fs::read("/usr/share/fonts/TTF/DejaVuSans.ttf").expect("system font");
        FontRef::try_from_slice(Box::leak(data.into_boxed_slice())).expect("font parse")
    }

    /// Render an A4-sized text page (1240x1754) with one line per entry.
    fn render_text_page(font: &FontRef, lines: &[&str], fg: Rgb<u8>, bg: Rgb<u8>) -> RgbImage {
        let mut img = RgbImage::from_pixel(1240, 1754, bg);
        for (i, text) in lines.iter().enumerate() {
            draw_text_mut(
                &mut img,
                fg,
                60,
                100 + i as i32 * 120,
                PxScale::from(52.0),
                font,
                text,
            );
        }
        img
    }

    /// Scan an RGB page through the real engine (RGB -> RGBA page contract).
    fn scan_rgb(img: &RgbImage, mode: &str) -> OcrResult {
        let rgba = image::DynamicImage::ImageRgb8(img.clone()).to_rgba8();
        let page = PageImage {
            rgba: &rgba.into_raw(),
            width: img.width(),
            height: img.height(),
        };
        RapidOcrEngine.scan(&page, mode).expect("scan should succeed")
    }

    /// Assert a keyword was recognized and every rect is in-bounds.
    fn assert_reads(out: &OcrResult, keyword: &str) {
        let texts: Vec<&str> = out.lines.iter().map(|l| l.text.as_str()).collect();
        eprintln!("lines: {texts:?}");
        assert!(!out.lines.is_empty(), "no text lines detected: {texts:?}");
        assert!(
            texts.iter().any(|t| t.to_lowercase().contains(keyword)),
            "expected {keyword:?} among {texts:?}"
        );
        for l in &out.lines {
            assert!((0.0..=1.0).contains(&l.x) && (0.0..=1.0).contains(&l.y));
        }
    }

    /// End-to-end scan: renders a synthetic A4 page (1240x1754) and runs the
    /// real engine through det -> cls -> rec in both modes, printing timing
    /// (perf targets: fast <= 0.5s/page, high_precision <= 3s/page on a
    /// typical page). Requires the PP-OCRv4 models installed by
    /// `scripts/download_ocr_models.sh`; run with `cargo test -- --ignored`.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_scans_a_synthetic_text_page() {
        let font = test_font();
        let img = render_text_page(
            &font,
            &[
                "Hello OCR pipeline",
                "PP-OCRv4 det / cls / rec",
                "Rust + ONNX Runtime, fully offline",
                "The quick brown fox jumps over the lazy dog",
            ],
            Rgb([0, 0, 0]),
            Rgb([255, 255, 255]),
        );

        let engine = RapidOcrEngine;
        assert!(engine.is_available(), "models not installed");
        for mode in ["fast", "high_precision"] {
            let start = std::time::Instant::now();
            let out = engine
                .scan(
                    &PageImage {
                        rgba: &image::DynamicImage::ImageRgb8(img.clone()).to_rgba8().into_raw(),
                        width: 1240,
                        height: 1754,
                    },
                    mode,
                )
                .expect("scan should succeed");
            let elapsed = start.elapsed();
            let texts: Vec<&str> = out.lines.iter().map(|l| l.text.as_str()).collect();
            eprintln!("[{mode}] {elapsed:?}  lines: {texts:?}");
            assert!(!out.lines.is_empty(), "[{mode}] no text lines detected");
            assert!(
                texts.iter().any(|t| t.to_lowercase().contains("hello")),
                "expected 'hello' among {texts:?}"
            );
            // Lines carry normalized rects inside the page bounds.
            for l in &out.lines {
                assert!((0.0..=1.0).contains(&l.x) && (0.0..=1.0).contains(&l.y));
            }
        }
    }

    /// 7.1.10: a washed-out scan (150-gray text on 245-gray paper) must still
    /// read after the adaptive contrast stretch. Run in fast mode only --
    /// enhancement is mode-independent, and this keeps the suite fast.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_low_contrast_page_reads_after_enhance() {
        let font = test_font();
        let page = render_text_page(
            &font,
            &["washed out scan", "low contrast page"],
            Rgb([150, 150, 150]),
            Rgb([245, 245, 245]),
        );
        assert_reads(&scan_rgb(&page, "fast"), "washed");
    }

    /// 7.1.11: a 15°-tilted page must still read -- det emits tilted quads
    /// and rec's perspective warp straightens each crop (quad -> rec path).
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_tilted_15_degree_page_reads() {
        use imageproc::geometric_transformations::{rotate_about_center, Interpolation};
        let font = test_font();
        let page = render_text_page(
            &font,
            &["tilted page", "quad perspective", "fifteen degrees"],
            Rgb([0, 0, 0]),
            Rgb([255, 255, 255]),
        );
        let tilted = rotate_about_center(
            &page,
            15.0f32.to_radians(),
            Interpolation::Bilinear,
            Rgb([255, 255, 255]),
        );
        assert_reads(&scan_rgb(&tilted, "fast"), "tilted");
    }

    /// 7.1.12: a page scanned 90° sideways must be read and its rects mapped
    /// back to the source (rotated) image: each line comes out as a tall
    /// vertical strip (h > w) rather than leaking the retry pass's
    /// horizontal coordinates.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_rotated_90_page_reads_with_mapped_coordinates() {
        let font = test_font();
        let page = render_text_page(
            &font,
            &["sideways page", "rotate ninety", "vertical strips"],
            Rgb([0, 0, 0]),
            Rgb([255, 255, 255]),
        );
        let rotated = image::imageops::rotate90(&page);
        let out = scan_rgb(&rotated, "fast");
        assert_reads(&out, "sideways");
        for l in &out.lines {
            assert!(
                l.h > l.w,
                "expected a tall source-space rect, got {:?}",
                (l.x, l.y, l.w, l.h)
            );
        }
    }

    /// 7.1.12 (180° half): a flipped page is corrected inside the pipeline
    /// by the cls model -- no re-scan needed, text reads normally.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_rotated_180_page_reads_via_cls() {
        let font = test_font();
        let page = render_text_page(
            &font,
            &["upside down", "cls correction", "still readable"],
            Rgb([0, 0, 0]),
            Rgb([255, 255, 255]),
        );
        let rotated = image::imageops::rotate180(&page);
        assert_reads(&scan_rgb(&rotated, "fast"), "upside");
    }

    /// Mixed layout: a horizontal block plus a vertical column on the right
    /// (upright glyphs stacked top-to-bottom, like Chinese 竖排). The
    /// engine's tall-crop handling rotates the column back before rec.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_mixed_vertical_and_horizontal_page_reads() {
        let font = test_font();
        let mut page = render_text_page(
            &font,
            &["horizontal block", "left to right"],
            Rgb([0, 0, 0]),
            Rgb([255, 255, 255]),
        );
        // 200x400 canvas with upright glyphs stacked at 44px pitch; a column
        // crop has h/w ~12, well past the 1.5 vertical-handling gate.
        let mut strip = RgbImage::from_pixel(200, 400, Rgb([255, 255, 255]));
        for (i, ch) in "VERTICAL".chars().enumerate() {
            draw_text_mut(
                &mut strip,
                Rgb([0, 0, 0]),
                40,
                30 + i as i32 * 44,
                PxScale::from(44.0),
                &font,
                &ch.to_string(),
            );
        }
        image::imageops::replace(&mut page, &strip, 1020, 100);

        let out = scan_rgb(&page, "fast");
        assert_reads(&out, "horizontal");
        let texts: Vec<&str> = out.lines.iter().map(|l| l.text.as_str()).collect();
        // The column may come back as one merged "VERTICAL" line or as
        // per-glyph boxes -- either way its letters must be present.
        assert!(
            texts.iter().any(|t| t.to_lowercase().contains("vertical"))
                || texts.iter().filter(|t| t.len() == 1).count() >= 4,
            "vertical column lost: {texts:?}"
        );
    }
}
