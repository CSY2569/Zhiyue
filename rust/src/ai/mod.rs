//! AI subsystem (FEATURES §6, TECH_ROADMAP §3.6).
//!
//! OpenAI-compatible client (BYOK): streaming chat + multimodal vision.
//! Prompt construction lives in [`prompts`] as pure functions; the wire
//! client is [`OpenAiClient`] (gated behind the `ai` cargo feature -- a stub
//! keeps the crate compiling without it).
//!
//! All calls stream (FEATURES 6.3.1); cancellation is implicit (dropping the
//! Dart-side subscription drops the Rust stream, aborting the request, 6.3.2).
//! API keys never leave the local machine (9.2.2).

use std::future::Future;
use std::pin::Pin;

use futures_core::Stream;

use crate::error::AppResult;
use crate::models::ai::{AiConfig, AiMessage};

/// System prompts for the AI actions (FEATURES 6.2).
pub mod prompts;

/// Prompt-injection defense for untrusted text: sanitization and
/// per-request nonce boundaries (search results, selected book text).
pub mod search_safety;

#[cfg(feature = "ai")]
mod openai;
#[cfg(feature = "ai")]
mod web_search;
#[cfg(feature = "ai")]
pub use openai::{web_search, OpenAiClient};
#[cfg(feature = "ai")]
pub(crate) use openai::{web_search_builtin, web_search_builtin_anthropic, RequestExtras};
#[cfg(feature = "ai")]
pub use web_search::deepseek_search;

/// A streamed text chunk from the model (FEATURES 6.3.1).
pub type ChunkStream = Pin<Box<dyn Stream<Item = AppResult<String>> + Send>>;

/// Effective vision model: the dedicated vision model wins, else the text
/// model (FEATURES 6.1.2: vision falls back to the main config when empty).
pub(crate) fn vision_model(config: &AiConfig) -> &str {
    if config.vision_model.trim().is_empty() {
        &config.text_model
    } else {
        &config.vision_model
    }
}

/// Effective `(base_url, api_key, model)` for a vision request (6.1.2).
///
/// When the general model declares image support (`model_supports_vision`,
/// 设置 → 模型能力 → 图片) every independent-vision override is inert: the
/// request follows the general channel, exactly like the settings page shows
/// it. Historical leftovers in the config must not hijack the request (a
/// stale base URL / key used to send 识图 to the previous provider).
///
/// A text-only general model still uses the overrides; blank ones
/// (`Some("")` / whitespace, possible from older builds) fall back.
pub(crate) fn vision_route(config: &AiConfig) -> (&str, &str, &str) {
    if config.model_supports_vision {
        return (&config.base_url, &config.api_key, &config.text_model);
    }
    let base = non_blank(config.vision_base_url.as_deref()).unwrap_or(&config.base_url);
    let key = non_blank(config.vision_api_key.as_deref()).unwrap_or(&config.api_key);
    (base, key, vision_model(config))
}

/// `Some(value)` only when [value] is not blank.
fn non_blank(value: Option<&str>) -> Option<&str> {
    value.filter(|v| !v.trim().is_empty())
}

/// The AI client contract.
///
/// Methods return `impl Future + Send` (RPITIT) so callers can run them on
/// FRB's multi-threaded executor (an `async fn` here would lose the `Send`
/// bound, which `wrap_async` requires).
pub trait AiClient: Send + Sync {
    /// Streaming chat completion. `history` carries prior turns (6.5.2),
    /// including any system prompt the caller prepended.
    /// Returns a stream of text chunks for incremental Markdown rendering.
    fn stream_chat(
        &self,
        config: &AiConfig,
        history: &[AiMessage],
        user_input: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send;

    /// Streaming vision analysis (识图, FEATURES 6.6.2): `png` holds the
    /// captured region screenshot, `prompt` the instruction that goes with
    /// it. Streams text chunks like [Self::stream_chat].
    fn stream_vision(
        &self,
        config: &AiConfig,
        png: &[u8],
        prompt: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send;
}

/// Stub implementation, compiled only without the `ai` feature so the crate
/// still builds when AI support is disabled. Stateless -- every call returns
/// an explicit error.
#[cfg(not(feature = "ai"))]
pub struct StubAiClient;

#[cfg(not(feature = "ai"))]
impl StubAiClient {
    pub fn new() -> Self {
        Self
    }
}

#[cfg(not(feature = "ai"))]
impl AiClient for StubAiClient {
    fn stream_chat(
        &self,
        _config: &AiConfig,
        _history: &[AiMessage],
        _user_input: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send {
        async {
            Err(crate::error::AppError::Ai(
                "AI support not compiled in (feature 'ai' disabled)".into(),
            ))
        }
    }
    fn stream_vision(
        &self,
        _config: &AiConfig,
        _png: &[u8],
        _prompt: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send {
        async {
            Err(crate::error::AppError::Ai(
                "AI support not compiled in (feature 'ai' disabled)".into(),
            ))
        }
    }
}
