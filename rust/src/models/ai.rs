//! AI models (FEATURES 9.1.7, §6).
//!
//! Thread + message model for persisted multi-turn conversations (6.5.4).
//! `AiConfig` mirrors the settings form (6.1). Milestone: M4.

use serde::{Deserialize, Serialize};

/// AI action that originated a thread (FEATURES 6.5.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AiActionType {
    Translate,
    Explain,
    Search,
    Chat,
    Vision,
}

impl AiActionType {
    pub fn as_str(&self) -> &'static str {
        match self {
            AiActionType::Translate => "translate",
            AiActionType::Explain => "explain",
            AiActionType::Search => "search",
            AiActionType::Chat => "chat",
            AiActionType::Vision => "vision",
        }
    }

    /// Inverse of [AiActionType::as_str] for DB rows (schema stores TEXT).
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "translate" => Some(Self::Translate),
            "explain" => Some(Self::Explain),
            "search" => Some(Self::Search),
            "chat" => Some(Self::Chat),
            "vision" => Some(Self::Vision),
            _ => None,
        }
    }
}

/// Chat message role (OpenAI-compatible).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AiRole {
    User,
    Assistant,
    System,
}

impl AiRole {
    pub fn as_str(&self) -> &'static str {
        match self {
            AiRole::User => "user",
            AiRole::Assistant => "assistant",
            AiRole::System => "system",
        }
    }

    /// Inverse of [AiRole::as_str] for DB rows.
    pub fn from_db_str(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            "system" => Some(Self::System),
            _ => None,
        }
    }
}

/// A persisted AI conversation window (table: ai_threads). One window per
/// book (FEATURES 6.5.4): every AI exchange inside a book shares its window;
/// `book_id` is null for conversations started without an open book.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiThread {
    pub id: i64,
    /// Window title: the book title snapshot (or "未打开书籍" without one).
    pub title: String,
    /// Latest action performed in the window (icon in the history list).
    pub action_type: AiActionType,
    /// The book this window belongs to; null = no-book window. No FK: the
    /// conversation survives book deletion (deletion is a user choice).
    pub book_id: Option<i64>,
    pub created_at: String,
    pub updated_at: String,
}

/// A single message in a thread (table: ai_messages).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiMessage {
    pub id: i64,
    pub thread_id: i64,
    pub role: AiRole,
    /// Markdown content (rendered with flutter_markdown + LaTeX on the Dart side).
    pub content: String,
    /// Vision screenshot file (relative to the app data dir), when this
    /// message carried a 区域识图 capture (v4, FEATURES 6.6.2).
    pub image_path: Option<String>,
    pub created_at: String,
}

/// BYOK AI configuration (FEATURES 6.1). Stored in the `settings` table;
/// API keys never leave the local machine (FEATURES 9.2.2).
///
/// `#[serde(default)]`: JSON stored by older builds may lack newer fields.
/// Without it, a missing non-Option field (e.g. `search_use_builtin`) fails
/// the whole read and the UI would show an empty config.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AiConfig {
    /// Base URL for the text model (OpenAI-compatible).
    pub base_url: String,
    pub api_key: String,
    pub text_model: String,
    pub vision_model: String,
    /// Optional independent vision config; falls back to the above when empty (6.1.2).
    pub vision_base_url: Option<String>,
    pub vision_api_key: Option<String>,
    /// Web-search provider config (6.1.4): two modes -- built-in search via
    /// the Responses API (`search_use_builtin`, DeepSeek web_search tool,
    /// reuses the text config) or a third-party Bocha-compatible endpoint.
    /// Empty `search_base_url` uses the Bocha default; empty `search_api_key`
    /// disables real web search.
    pub search_use_builtin: bool,
    pub search_base_url: Option<String>,
    pub search_api_key: Option<String>,
    /// Translation target language, default "中文" (6.1.3).
    pub translate_target_lang: String,
    /// Web search toggle (6.1.4).
    pub web_search_enabled: bool,
    /// Full-page OCR model set (7.1.9): "high_precision" (server models,
    /// accuracy first) or "fast" (mobile models, speed / size). Field-level
    /// default so configs saved by older builds read a valid value.
    #[serde(default = "default_ocr_mode")]
    pub ocr_mode: String,
    /// Carry the book's full conversation history on every request
    /// (default: the window history -- 追问 always sends the thread's turns
    /// from the start; off = every turn is answered independently).
    #[serde(default = "default_true")]
    pub include_book_history: bool,
    /// Thinking mode (reasoning models): the request carries
    /// `reasoning_effort` per the official API docs when enabled.
    #[serde(default)]
    pub enable_reasoning: bool,
    /// Reasoning level when [enable_reasoning]: "low" | "medium" | "high".
    #[serde(default = "default_reasoning_effort")]
    pub reasoning_effort: String,
    /// Sampling temperature for text replies (0.0-2.0, OpenAI range).
    #[serde(default = "default_temperature")]
    pub temperature: f64,
    /// Role template for text replies: "general" | "academic" | "novel" |
    /// "tech" | "language" | "custom" (the role segment is prepended to the
    /// per-action system prompt).
    #[serde(default = "default_prompt_template")]
    pub prompt_template: String,
    /// User-written role prompt when [prompt_template] is "custom".
    #[serde(default)]
    pub custom_prompt: String,
}

fn default_ocr_mode() -> String {
    "high_precision".to_string()
}

fn default_true() -> bool {
    true
}

fn default_reasoning_effort() -> String {
    "medium".to_string()
}

fn default_temperature() -> f64 {
    0.7
}

fn default_prompt_template() -> String {
    "general".to_string()
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            base_url: String::new(), // empty -> provider default endpoint
            api_key: String::new(),
            text_model: String::new(),
            vision_model: String::new(),
            vision_base_url: None,
            vision_api_key: None,
            search_use_builtin: false,
            search_base_url: None,
            search_api_key: None,
            translate_target_lang: "中文".to_string(),
            web_search_enabled: false,
            ocr_mode: "high_precision".to_string(),
            include_book_history: true,
            enable_reasoning: false,
            reasoning_effort: "medium".to_string(),
            temperature: 0.7,
            prompt_template: "general".to_string(),
            custom_prompt: String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// JSON persisted by an older build (before search fields existed) must
    /// still deserialize; missing fields fall back to their defaults instead
    /// of failing the whole read (regression: config vanished after adding
    /// the non-Option `search_use_builtin` field).
    #[test]
    fn ai_config_deserializes_legacy_json_without_new_fields() {
        let legacy = r#"{
            "base_url": "https://api.deepseek.com/v1",
            "api_key": "sk-test",
            "text_model": "deepseek-chat",
            "vision_model": "deepseek-vl",
            "vision_base_url": null,
            "vision_api_key": null,
            "translate_target_lang": "中文",
            "web_search_enabled": true
        }"#;
        let cfg: AiConfig = serde_json::from_str(legacy).expect("legacy json must load");
        assert_eq!(cfg.api_key, "sk-test");
        assert_eq!(cfg.base_url, "https://api.deepseek.com/v1");
        assert!(cfg.web_search_enabled);
        // Newer fields default rather than error.
        assert!(!cfg.search_use_builtin);
        assert!(cfg.search_base_url.is_none());
        assert!(cfg.search_api_key.is_none());

        // Round-trip through the current serializer keeps working.
        let back: AiConfig =
            serde_json::from_str(&serde_json::to_string(&cfg).unwrap()).unwrap();
        assert_eq!(back.api_key, "sk-test");
        assert_eq!(back.translate_target_lang, "中文");
        assert!(!back.search_use_builtin);
    }

    #[test]
    fn ai_config_roundtrip_preserves_all_fields() {
        let cfg = AiConfig {
            base_url: "https://api.openai.com/v1".into(),
            api_key: "sk-1".into(),
            text_model: "gpt-4o-mini".into(),
            vision_model: "qwen-vl-max".into(),
            vision_base_url: Some("https://v.example/v1".into()),
            vision_api_key: Some("sk-v".into()),
            search_use_builtin: true,
            search_base_url: Some("https://s.example/search".into()),
            search_api_key: Some("sk-s".into()),
            translate_target_lang: "中文".into(),
            web_search_enabled: true,
            ocr_mode: "fast".into(),
            include_book_history: false,
            enable_reasoning: true,
            reasoning_effort: "high".into(),
            temperature: 0.3,
            prompt_template: "tech".into(),
            custom_prompt: "自定义角色".into(),
        };
        let back: AiConfig = serde_json::from_str(&serde_json::to_string(&cfg).unwrap()).unwrap();
        assert_eq!(back.base_url, cfg.base_url);
        assert_eq!(back.api_key, cfg.api_key);
        assert_eq!(back.text_model, cfg.text_model);
        assert_eq!(back.vision_model, cfg.vision_model);
        assert_eq!(back.vision_base_url, cfg.vision_base_url);
        assert_eq!(back.vision_api_key, cfg.vision_api_key);
        assert!(back.search_use_builtin);
        assert_eq!(back.search_base_url, cfg.search_base_url);
        assert_eq!(back.search_api_key, cfg.search_api_key);
        assert_eq!(back.translate_target_lang, "中文");
        assert!(back.web_search_enabled);
        assert_eq!(back.ocr_mode, "fast");
        assert!(!back.include_book_history);
        assert!(back.enable_reasoning);
        assert_eq!(back.reasoning_effort, "high");
        assert!((back.temperature - 0.3).abs() < 1e-9);
        assert_eq!(back.prompt_template, "tech");
        assert_eq!(back.custom_prompt, "自定义角色");

        // A config saved by an older build (no ocr_mode) still loads: the
        // serde default kicks in.
        let legacy: AiConfig =
            serde_json::from_str(r#"{"base_url":"","api_key":"","text_model":"","vision_model":""}"#)
                .unwrap();
        assert_eq!(legacy.ocr_mode, "high_precision");
        assert!(legacy.include_book_history);
        assert!(!legacy.enable_reasoning);
        assert_eq!(legacy.reasoning_effort, "medium");
        assert!((legacy.temperature - 0.7).abs() < 1e-9);
        assert_eq!(legacy.prompt_template, "general");
    }
}
