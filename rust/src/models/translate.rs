//! Bilingual reading models (M7, `docs/BILINGUAL_READING_PLAN.md`).
//!
//! Types crossing the Rust <-> Dart FFI boundary for the 对照阅读 feature:
//! per-page paragraph extraction, paragraph-level translation results, the
//! per-page translation cache payload, whole-book progress and stream
//! progress events. Pages are **1-indexed** throughout the translation APIs
//! (matching the UI's `currentPage`), unlike pdfium's 0-indexed pages.

use serde::{Deserialize, Serialize};

use super::annotation::NormRect;

/// Translation service selection (plan §8). `ReuseAi` reuses the AI settings'
/// OpenAI-compatible config for LLM translation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TranslationProviderKind {
    DeepL,
    OpenAiCompat,
    ReuseAi,
}

impl TranslationProviderKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::DeepL => "deepl",
            Self::OpenAiCompat => "openai_compat",
            Self::ReuseAi => "reuse_ai",
        }
    }

    /// Inverse of [TranslationProviderKind::as_str] (cache key / DB TEXT).
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "deepl" => Some(Self::DeepL),
            "openai_compat" => Some(Self::OpenAiCompat),
            "reuse_ai" => Some(Self::ReuseAi),
            _ => None,
        }
    }
}

/// When pages get translated (plan §10). Default: translate the visible page
/// plus the next two as the user reads (随进度).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TranslationMode {
    WholeBook,
    WithProgress,
    Manual,
}

impl TranslationMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::WholeBook => "whole_book",
            Self::WithProgress => "with_progress",
            Self::Manual => "manual",
        }
    }

    /// Inverse of [TranslationMode::as_str].
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "whole_book" => Some(Self::WholeBook),
            "with_progress" => Some(Self::WithProgress),
            "manual" => Some(Self::Manual),
            _ => None,
        }
    }
}

/// What happens to a running whole-book translation when the user switches
/// books / closes the pane (plan §8, user decision). `Ask` is the default
/// until the user picks a behaviour in the first-run dialog.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TranslationBackgroundBehavior {
    Ask,
    /// Keep translating in the background (switching books does not cancel).
    Continue,
    /// Pause on book switch, resume automatically when the book reopens.
    PauseResume,
    /// Cancel as soon as the user leaves the book / closes the pane.
    Cancel,
}

impl TranslationBackgroundBehavior {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Continue => "continue",
            Self::PauseResume => "pause_resume",
            Self::Cancel => "cancel",
        }
    }

    /// Inverse of [TranslationBackgroundBehavior::as_str].
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "ask" => Some(Self::Ask),
            "continue" => Some(Self::Continue),
            "pause_resume" => Some(Self::PauseResume),
            "cancel" => Some(Self::Cancel),
            _ => None,
        }
    }
}

/// 对照阅读 configuration (plan §8). Stored in the `settings` table under the
/// key `translation_config` as one JSON value. The **target language is NOT
/// configured here** (v4.2 user decision): it is shared with the AI settings'
/// `AiConfig.translate_target_lang`.
///
/// `#[serde(default)]`: the whole config is one JSON blob; fields added by
/// newer builds must default cleanly when older JSON is read (mirrors
/// [super::ai::AiConfig]).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct TranslationConfig {
    /// Translation service (DeepL / generic OpenAI-compatible / reuse AI).
    pub provider: TranslationProviderKind,
    /// DeepL / OpenAI-compatible endpoint override. Empty = DeepL picks the
    /// free/pro endpoint from the key (":fx" suffix), OpenAI-compat requires
    /// an explicit base URL.
    pub base_url: Option<String>,
    pub api_key: Option<String>,
    /// Model name (OpenAI-compatible / reuse-AI override). Empty = the AI
    /// settings' text model.
    pub model: Option<String>,
    /// Source language: "auto" (default) or a specific language name / code.
    pub source_lang: String,
    /// When pages are translated (plan §10). Default 随进度.
    pub mode: TranslationMode,
    /// Whole-book background behaviour (plan §10), default `Ask`.
    pub background_behavior: TranslationBackgroundBehavior,
    /// Auto-OCR scanned pages (no text layer) before translating (plan §3.5).
    pub auto_ocr: bool,
    /// Concurrent page translations for whole-book mode (1-8).
    pub concurrency: i64,
    /// Translation cache budget in MB (plan §7, default 2GB).
    pub cache_limit_mb: i64,
}

fn default_translation_provider() -> TranslationProviderKind {
    TranslationProviderKind::ReuseAi
}

fn default_source_lang() -> String {
    "auto".to_string()
}

fn default_translation_mode() -> TranslationMode {
    TranslationMode::WithProgress
}

fn default_background_behavior() -> TranslationBackgroundBehavior {
    TranslationBackgroundBehavior::Ask
}

fn default_auto_ocr() -> bool {
    true
}

fn default_concurrency() -> i64 {
    2
}

fn default_cache_limit_mb() -> i64 {
    2048
}

impl Default for TranslationConfig {
    fn default() -> Self {
        // Keep in sync with the serde default functions above (a drift breaks
        // the "old JSON reads a valid config" guarantee, see AiConfig).
        Self {
            provider: default_translation_provider(),
            base_url: None,
            api_key: None,
            model: None,
            source_lang: default_source_lang(),
            mode: default_translation_mode(),
            background_behavior: default_background_behavior(),
            auto_ocr: default_auto_ocr(),
            concurrency: default_concurrency(),
            cache_limit_mb: default_cache_limit_mb(),
        }
    }
}

/// What a paragraph is (plan §3): normal text, a whole-paragraph formula
/// (kept as an image, never machine-translated), or removed noise
/// (header / footer / page number).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParagraphKind {
    Text,
    Formula,
    Noise,
}

impl ParagraphKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Formula => "formula",
            Self::Noise => "noise",
        }
    }

    /// Inverse of [ParagraphKind::as_str].
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "text" => Some(Self::Text),
            "formula" => Some(Self::Formula),
            "noise" => Some(Self::Noise),
            _ => None,
        }
    }
}

/// Per-paragraph translation status in the pane (plan §5).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ParagraphStatus {
    Pending,
    Translating,
    Done,
    /// OCR confidence < 0.8 (plan §3.5): shown with a "请核对" hint.
    LowConfidence,
    Failed,
    /// Placeholder backfill validation failed: the formula may be wrong.
    FormulaCheck,
}

impl ParagraphStatus {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Translating => "translating",
            Self::Done => "done",
            Self::LowConfidence => "low_confidence",
            Self::Failed => "failed",
            Self::FormulaCheck => "formula_check",
        }
    }

    /// Inverse of [ParagraphStatus::as_str].
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "pending" => Some(Self::Pending),
            "translating" => Some(Self::Translating),
            "done" => Some(Self::Done),
            "low_confidence" => Some(Self::LowConfidence),
            "failed" => Some(Self::Failed),
            "formula_check" => Some(Self::FormulaCheck),
            _ => None,
        }
    }
}

/// A formula region detected from font metadata (plan §3.4): the rect on
/// the original page plus the raw formula text. `image_path`/`placeholder`
/// are VESTIGES of the retired region-image pipeline: extraction never
/// sets them anymore (whole-paragraph formulas keep their original page
/// pixels; inline tokens are built dynamically by the translation layer).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FormulaRegion {
    /// Normalized rect (top-left origin, Flutter space), same convention as
    /// annotation rects.
    pub rect: NormRect,
    /// Always `None` since the region-image pipeline was removed; kept for
    /// cache-row compatibility.
    pub image_path: Option<String>,
    /// The raw formula text as it appeared on the page.
    pub source_text: String,
    /// Always empty since the region-image pipeline was removed; kept for
    /// cache-row compatibility.
    pub placeholder: String,
}

/// One reconstructed paragraph of a page (plan §3): text + line rects +
/// formula regions found inside it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Paragraph {
    pub text: String,
    /// Bounding rects of the paragraph's lines (normalized).
    pub rects: Vec<NormRect>,
    /// 1-indexed page number.
    pub page: i64,
    pub kind: ParagraphKind,
    /// 1.0 for text-layer paragraphs; the minimum OCR line confidence
    /// otherwise.
    pub confidence: f64,
    pub formula_regions: Vec<FormulaRegion>,
}

/// A paragraph with its translation (plan §4-5). `translated` still contains
/// the formula placeholder tokens: consumers substitute them with
/// [FormulaRegion::source_text].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TranslatedParagraph {
    pub source: String,
    /// Machine translation with `⟨..MATH_n⟩` tokens still in place (may be
    /// empty for whole-paragraph formulas, which keep their original pixels).
    pub translated: String,
    pub kind: ParagraphKind,
    pub status: ParagraphStatus,
    pub confidence: f64,
    pub formula_regions: Vec<FormulaRegion>,
    /// Bounding rects of the paragraph's LINES (normalized, top-left origin),
    /// copied from the extracted [Paragraph]. The overlay writer draws the
    /// translation at this footprint; empty for rows cached before v3 (such
    /// rows are rejected as stale before reaching the writer).
    #[serde(default)]
    pub rects: Vec<NormRect>,
}

/// The cached translation of one page (table: `page_translation_cache`).
/// The cache key is (book_id, page, target_lang, provider); `source_hash`
/// guards freshness (a re-extracted page that changed invalidates the row).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageTranslation {
    /// 1-indexed page number (plan §2: absolute page number, never reorder).
    pub page: i64,
    pub target_lang: String,
    /// Provider id string (`deepl` / `openai_compat` / `reuse_ai`).
    pub provider: String,
    /// SHA-256 of the page's paragraph texts at translation time.
    pub source_hash: String,
    pub paragraphs: Vec<TranslatedParagraph>,
    /// Fraction of translatable paragraphs (text kind, noise/formula
    /// excluded) with a non-empty translation (plan §4.7).
    pub coverage: f64,
}

/// Whole-book translation progress for the resume decision (plan §9).
#[derive(Debug, Clone)]
pub struct TranslationOverview {
    pub book_id: i64,
    /// Total page count of the book.
    pub total_pages: i64,
    /// Pages with a cached translation for the current target lang + provider.
    pub translated_pages: i64,
    /// The target language this overview was computed for.
    pub target_lang: String,
}

/// One progress event of a `translate_page` / `build_translated_pdf` stream.
#[derive(Debug, Clone)]
pub struct TranslationProgressEvent {
    /// 1-indexed page the event belongs to.
    pub page: i64,
    /// Paragraphs finished on the page (translate events). Build events are
    /// page-granular: this echoes the page number as the pages-done count.
    pub done_paragraphs: i64,
    pub total_paragraphs: i64,
    /// Page coverage fraction (translate events).
    pub coverage: f64,
    /// Whether the stream has completed (page done / whole build done).
    pub finished: bool,
    pub error: Option<String>,
}

/// One glossary entry (table: `translation_glossary`, plan §4.4): a fixed
/// term pair applied to every translation for consistent naming.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GlossaryEntry {
    pub id: i64,
    pub source_term: String,
    pub target_term: String,
    /// Optional language pair restriction (DeepL glossaries are per pair);
    /// null = applies everywhere.
    pub source_lang: Option<String>,
    pub target_lang: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The config is one JSON blob: fields added by newer builds must
    /// default cleanly when older JSON is read (AiConfig regression pattern).
    #[test]
    fn translation_config_defaults_and_legacy_json() {
        let cfg = TranslationConfig::default();
        assert_eq!(cfg.provider, TranslationProviderKind::ReuseAi);
        assert_eq!(cfg.source_lang, "auto");
        assert_eq!(cfg.mode, TranslationMode::WithProgress);
        assert_eq!(cfg.background_behavior, TranslationBackgroundBehavior::Ask);
        assert!(cfg.auto_ocr);
        assert_eq!(cfg.concurrency, 2);
        assert_eq!(cfg.cache_limit_mb, 2048);

        // Legacy JSON (only some fields) reads with defaults.
        let legacy: TranslationConfig =
            serde_json::from_str(r#"{"source_lang":"EN"}"#).unwrap();
        assert_eq!(legacy.source_lang, "EN");
        assert_eq!(legacy.mode, TranslationMode::WithProgress);
        assert!(!matches!(
            legacy.provider,
            TranslationProviderKind::DeepL
        ));

        // Round-trip.
        let cfg = TranslationConfig {
            provider: TranslationProviderKind::DeepL,
            base_url: Some("https://api-free.deepl.com".into()),
            api_key: Some("k:fx".into()),
            model: None,
            source_lang: "auto".into(),
            mode: TranslationMode::WholeBook,
            background_behavior: TranslationBackgroundBehavior::PauseResume,
            auto_ocr: false,
            concurrency: 4,
            cache_limit_mb: 1024,
        };
        let back: TranslationConfig =
            serde_json::from_str(&serde_json::to_string(&cfg).unwrap()).unwrap();
        assert_eq!(back.provider, TranslationProviderKind::DeepL);
        assert_eq!(back.mode, TranslationMode::WholeBook);
        assert_eq!(
            back.background_behavior,
            TranslationBackgroundBehavior::PauseResume
        );
        assert!(!back.auto_ocr);
        assert_eq!(back.concurrency, 4);
        assert_eq!(back.cache_limit_mb, 1024);
    }

    #[test]
    fn enum_db_str_roundtrip() {
        for s in ["deepl", "openai_compat", "reuse_ai"] {
            assert_eq!(
                TranslationProviderKind::from_db_str(s).unwrap().as_str(),
                s
            );
        }
        for s in ["whole_book", "with_progress", "manual"] {
            assert_eq!(TranslationMode::from_db_str(s).unwrap().as_str(), s);
        }
        for s in ["ask", "continue", "pause_resume", "cancel"] {
            assert_eq!(
                TranslationBackgroundBehavior::from_db_str(s)
                    .unwrap()
                    .as_str(),
                s
            );
        }
        for s in ["text", "formula", "noise"] {
            assert_eq!(ParagraphKind::from_db_str(s).unwrap().as_str(), s);
        }
        for s in ["pending", "translating", "done", "low_confidence", "failed", "formula_check"] {
            assert_eq!(ParagraphStatus::from_db_str(s).unwrap().as_str(), s);
        }
    }

    #[test]
    fn page_translation_json_roundtrip() {
        let page = PageTranslation {
            page: 12,
            target_lang: "中文".into(),
            provider: "deepl".into(),
            source_hash: "abc".into(),
            paragraphs: vec![TranslatedParagraph {
                source: "Hello ⟨F1-MATH_0⟩ world".into(),
                translated: "你好 ⟨F1-MATH_0⟩ 世界".into(),
                kind: ParagraphKind::Text,
                status: ParagraphStatus::Done,
                confidence: 1.0,
                formula_regions: vec![FormulaRegion {
                    rect: NormRect { x: 0.1, y: 0.2, w: 0.3, h: 0.05 },
                    image_path: None,
                    source_text: "x^2".into(),
                    placeholder: "⟨F1-MATH_0⟩".into(),
                }],
                rects: vec![NormRect { x: 0.1, y: 0.2, w: 0.3, h: 0.05 }],
            }],
            coverage: 1.0,
        };
        let back: PageTranslation =
            serde_json::from_str(&serde_json::to_string(&page).unwrap()).unwrap();
        assert_eq!(back.page, 12);
        assert_eq!(back.paragraphs.len(), 1);
        assert_eq!(back.paragraphs[0].translated, "你好 ⟨F1-MATH_0⟩ 世界");
        assert_eq!(back.paragraphs[0].formula_regions.len(), 1);
        assert_eq!(back.paragraphs[0].rects.len(), 1);

        // Legacy JSON without rects (pre-v3 rows) reads with empty rects.
        let legacy: TranslatedParagraph = serde_json::from_str(
            r#"{"source":"a","translated":"b","kind":"Text","status":"Done","confidence":1.0,"formula_regions":[]}"#,
        )
        .unwrap();
        assert!(legacy.rects.is_empty());
        assert_eq!(back.paragraphs[0].formula_regions[0].image_path, None);
    }
}
