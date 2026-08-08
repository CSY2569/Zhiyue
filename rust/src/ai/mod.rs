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

#[cfg(feature = "ai")]
mod openai;
#[cfg(feature = "ai")]
pub use openai::{web_search, OpenAiClient};
#[cfg(feature = "ai")]
pub(crate) use openai::{web_search_builtin, RequestExtras};

/// A streamed text chunk from the model (FEATURES 6.3.1).
pub type ChunkStream =
    Pin<Box<dyn Stream<Item = AppResult<String>> + Send>>;

/// The AI client contract.
///
/// Methods return `impl Future + Send` (RPITIT) so callers can run them on
/// FRB's multi-threaded executor.
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
/// still builds when AI support is disabled.
#[cfg(not(feature = "ai"))]
pub struct StubAiClient {
    pub _lock: tokio::sync::Mutex<()>,
}

#[cfg(not(feature = "ai"))]
impl StubAiClient {
    pub fn new() -> Self {
        Self { _lock: tokio::sync::Mutex::new(()) }
    }
}

#[cfg(not(feature = "ai"))]
impl AiClient for StubAiClient {
    async fn stream_chat(
        &self,
        _config: &AiConfig,
        _history: &[AiMessage],
        _user_input: &str,
    ) -> AppResult<ChunkStream> {
        Err(crate::error::AppError::Ai(
            "AI support not compiled in (feature 'ai' disabled)".into(),
        ))
    }
    async fn stream_vision(
        &self,
        _config: &AiConfig,
        _png: &[u8],
        _prompt: &str,
    ) -> AppResult<ChunkStream> {
        Err(crate::error::AppError::Ai(
            "AI support not compiled in (feature 'ai' disabled)".into(),
        ))
    }
}
