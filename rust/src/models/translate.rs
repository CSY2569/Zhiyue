//! Bilingual reading models (M7).
//!
//! Types crossing the Rust <-> Dart FFI boundary for the 对照阅读 feature.
//! The retired built-in pipeline's per-page models (paragraphs, page
//! translations, progress events) were removed together with the pipeline --
//! translation now runs on the downloadable BabelDOC engine; these are the
//! settings + glossary types that remain engine-independent. The engine's
//! install status / progress models live in `translate::engine`.

use serde::{Deserialize, Serialize};

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

/// Lifecycle of the downloadable translation engine (BabelDOC + pdf2zh-next
/// in a uv-managed Python environment under `app_data_dir/babeldoc`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EngineStatusKind {
    NotInstalled,
    Installing,
    Installed,
    Failed,
}

/// Current engine state for the settings card.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineStatus {
    pub kind: EngineStatusKind,
    /// Human-readable step label while installing ("下载 uv" / "安装依赖" /
    /// "下载模型资产" ...), empty otherwise.
    pub phase: String,
    /// Progress within the WHOLE install (0..1); 0 when not installing.
    pub progress: f64,
    /// Installed engine version (pdf2zh-next pin), empty when absent.
    pub version: String,
    /// On-disk size of the managed environment + assets, bytes (0 unknown).
    pub size_bytes: i64,
    pub error: Option<String>,
    /// Engine shipped inside the installation bundle (cannot be uninstalled;
    /// the settings card hides the removal affordance).
    pub bundled: bool,
}

/// A completed whole-book translation (manifest under
/// `translated/{book_id}/manifest.json`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookTranslation {
    pub book_id: i64,
    pub title: String,
    /// Display language the user configured (e.g. 中文).
    pub target_lang: String,
    /// BabelDOC language code used for the run (e.g. zh).
    pub lang_out: String,
    /// Absolute paths of the produced PDFs (mono = translated pages; dual =
    /// original + translation side by side on each page).
    pub mono_path: String,
    pub dual_path: String,
    pub pages: i64,
    pub finished_at: String,
    pub error: Option<String>,
}

/// One event of the whole-book translation stream.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookTranslateEvent {
    /// Coarse phase (解析版式 / 翻译中 / 排版输出 / 完成 / 失败).
    pub phase: String,
    /// Latest engine output line (progress detail).
    pub detail: String,
    /// Whether the run has ended (success or failure).
    pub done: bool,
    pub error: Option<String>,
}

/// One install-stream event.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EngineInstallEvent {
    pub phase: String,
    /// Progress within the whole install (0..1).
    pub progress: f64,
    /// Detail line (latest child-process output line / byte counts).
    pub detail: String,
    /// Whether the install has finished (success or failure).
    pub finished: bool,
    pub error: Option<String>,
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
    }
}