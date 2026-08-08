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
pub struct RapidOcrEngine;

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
                dict_path: dict_path,
                image_shape: REC_SHAPE,
                batch_size: 6,
            }),
        };
        RapidOcr::new(cfg)
            .map(|engine| Mutex::new(engine))
            .map_err(|e| format!("{e:#}"))
    }

    /// One scan run under the mode's engine lock.
    fn run(image: &PageImage<'_>, mode: &str) -> AppResult<OcrResult> {
        let slot = &ENGINES[Self::slot(mode)];
        let loaded = slot.get_or_init(|| Self::load(mode));
        let mut engine = loaded
            .as_ref()
            .map_err(|e| AppError::Ocr(e.clone()))?
            .lock()
            .map_err(|_| AppError::Ocr("OCR 引擎内部错误（锁中毒）".into()))?;

        let rgb = RgbImage::from_raw(
            image.width,
            image.height,
            to_rgb(image.rgba),
        )
        .ok_or_else(|| AppError::Ocr("页面图像数据无效".into()))?;
        let out = engine
            .run_image(&rgb)
            .map_err(|e| AppError::Ocr(format!("{e:#}")))?;

        let w = f64::from(image.width);
        let h = f64::from(image.height);
        let lines = out
            .lines
            .into_iter()
            .map(|l| normalize(l, w, h))
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
/// the normalized line rect of the OCR contract (Flutter space).
fn normalize(line: rapidocr_core::types::OcrLine, w: f64, h: f64) -> OcrLine {
    let pts = line.bbox.points;
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
        let n = normalize(line, 1000.0, 500.0);
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
        let n = normalize(line, 100.0, 100.0);
        assert_eq!(n.x, 0.0);
        assert_eq!(n.y, 0.0);
        assert_eq!(n.w, 0.16); // 16 / 100
    }

    #[test]
    fn model_files_detects_absence() {
        // An unknown mode can never have models installed.
        assert!(RapidOcrEngine::model_files("nonexistent-mode").is_none());
    }

    /// End-to-end scan: renders a synthetic A4 page (1240x1754) and runs the
    /// real engine through det -> cls -> rec in both modes, printing timing
    /// (perf targets: fast <= 0.5s/page, high_precision <= 3s/page on a
    /// typical page). Requires the PP-OCRv4 models installed by
    /// `scripts/download_ocr_models.sh`; run with `cargo test -- --ignored`.
    #[test]
    #[ignore = "requires downloaded OCR models"]
    fn e2e_scans_a_synthetic_text_page() {
        use ab_glyph::{FontRef, PxScale};
        use image::{Rgb, RgbImage};
        use imageproc::drawing::draw_text_mut;

        let font_data =
            std::fs::read("/usr/share/fonts/TTF/DejaVuSans.ttf").expect("system font");
        let font = FontRef::try_from_slice(&font_data).expect("font parse");
        let mut img = RgbImage::from_pixel(1240, 1754, Rgb([255, 255, 255]));
        for (i, text) in [
            "Hello OCR pipeline",
            "PP-OCRv4 det / cls / rec",
            "Rust + ONNX Runtime, fully offline",
            "The quick brown fox jumps over the lazy dog",
        ]
        .into_iter()
        .enumerate()
        {
            draw_text_mut(
                &mut img,
                Rgb([0, 0, 0]),
                60,
                100 + i as i32 * 120,
                PxScale::from(52.0),
                &font,
                text,
            );
        }

        let engine = RapidOcrEngine;
        assert!(engine.is_available(), "models not installed");
        // PageImage carries RGBA (the page render format); the test image is
        // RGB, so widen it.
        let rgba = image::DynamicImage::ImageRgb8(img).to_rgba8();
        let page = PageImage {
            rgba: &rgba.into_raw(),
            width: 1240,
            height: 1754,
        };

        for mode in ["fast", "high_precision"] {
            let start = std::time::Instant::now();
            let out = engine.scan(&page, mode).expect("scan should succeed");
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
}
