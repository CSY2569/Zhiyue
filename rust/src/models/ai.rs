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
}

/// A persisted AI conversation thread (table: ai_threads).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiThread {
    pub id: i64,
    pub title: String,
    pub action_type: AiActionType,
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
    pub created_at: String,
}

/// BYOK AI configuration (FEATURES 6.1). Stored in the `settings` table;
/// API keys never leave the local machine (FEATURES 9.2.2).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AiConfig {
    /// Base URL for the text model (OpenAI-compatible).
    pub base_url: String,
    pub api_key: String,
    pub text_model: String,
    pub vision_model: String,
    /// Optional independent vision config; falls back to the above when empty (6.1.2).
    pub vision_base_url: Option<String>,
    pub vision_api_key: Option<String>,
    /// Translation target language, default "中文" (6.1.3).
    pub translate_target_lang: String,
    /// Web search toggle (6.1.4).
    pub web_search_enabled: bool,
}
