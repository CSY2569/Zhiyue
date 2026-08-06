//! AI subsystem (FEATURES §6, TECH_ROADMAP §3.6).
//!
//! OpenAI-compatible client (BYOK): streaming chat + multimodal vision.
//! Backed by `async-openai` (M4), with a `reqwest` hand-written fallback for
//! providers whose multimodal format differs. At the skeleton stage the trait
//! is defined with a stub impl returning `todo!()`.
//!
//! All calls stream (FEATURES 6.3.1) and are cancellable (6.3.2). API keys
//! never leave the local machine (9.2.2).

use std::pin::Pin;

use futures_core::Stream;
use tokio::sync::Mutex;

use crate::error::AppResult;
use crate::models::ai::{AiConfig, AiMessage};

/// A streamed text chunk from the model (FEATURES 6.3.1).
pub type ChunkStream =
    Pin<Box<dyn Stream<Item = AppResult<String>> + Send>>;

/// The AI client contract.
#[allow(async_fn_in_trait)] // we keep it simple for the skeleton
pub trait AiClient: Send + Sync {
    /// Streaming chat completion. `history` carries prior turns (6.5.2).
    /// Returns a stream of text chunks for incremental Markdown rendering.
    async fn stream_chat(
        &self,
        config: &AiConfig,
        history: &[AiMessage],
        user_input: &str,
    ) -> AppResult<ChunkStream>;

    /// Multimodal vision call: analyze an image region (6.6.1).
    /// `image_rgba` + dims describe the cropped region screenshot.
    async fn vision(
        &self,
        config: &AiConfig,
        image_rgba: &[u8],
        width: u32,
        height: u32,
        prompt: &str,
    ) -> AppResult<ChunkStream>;

    /// Cancel the in-flight call associated with `call_id` (6.3.2).
    async fn cancel(&self, call_id: &str) -> AppResult<()>;
}

/// Stub implementation. Real impl (`OpenAiClient`) lands in M4.
pub struct StubAiClient {
    pub _lock: Mutex<()>,
}

impl StubAiClient {
    pub fn new() -> Self {
        Self { _lock: Mutex::new(()) }
    }
}

impl AiClient for StubAiClient {
    async fn stream_chat(
        &self,
        _config: &AiConfig,
        _history: &[AiMessage],
        _user_input: &str,
    ) -> AppResult<ChunkStream> {
        todo!("M4: async-openai stream_chat")
    }
    async fn vision(
        &self,
        _config: &AiConfig,
        _image_rgba: &[u8],
        _width: u32,
        _height: u32,
        _prompt: &str,
    ) -> AppResult<ChunkStream> {
        todo!("M4: async-openai vision")
    }
    async fn cancel(&self, _call_id: &str) -> AppResult<()> {
        todo!("M4: cancel in-flight call")
    }
}
