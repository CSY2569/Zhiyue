//! OpenAI-compatible client (FEATURES §6, M4).
//!
//! BYOK: base URL / key / models come from [`AiConfig`] (6.1). Both chat and
//! vision calls stream (6.3.1); cancelling is implicit -- the Dart side
//! cancels the FRB subscription, which drops this stream and aborts the
//! HTTP request (6.3.2).
//!
//! The transport is a hand-written reqwest SSE client (the TECH_ROADMAP
//! fallback for async-openai), for two reasons:
//! - non-2xx responses surface the full provider error body (async-openai's
//!   event-source path dropped it, leaving only "400");
//! - the request body is built by hand with only `model` / `messages` /
//!   `stream`, so no provider-rejected fields leak in (e.g. async-openai
//!   serialized `image_url.detail: null`, which Volcano Ark rejects with
//!   HTTP 400 -- the vision request therefore omits `detail` entirely).

use std::future::Future;
use std::time::Duration;

use futures_core::Stream;
use futures_util::StreamExt;
use serde_json::{json, Value};

use crate::ai::{AiClient, ChunkStream};
use crate::error::{AppError, AppResult};
use crate::models::ai::{AiConfig, AiMessage, AiRole};

/// Default endpoint when the config's base URL is empty (OpenAI official).
const DEFAULT_BASE_URL: &str = "https://api.openai.com/v1";

/// Bocha web search endpoint (FEATURES 6.2.3, real search integration).
const BOCHA_ENDPOINT: &str = "https://api.bochaai.com/v1/web-search";

/// How long a web search call may take before the chat falls back.
const WEB_SEARCH_TIMEOUT: Duration = Duration::from_secs(20);

/// OpenAI-compatible client backed by reqwest (M4).
pub struct OpenAiClient;

impl OpenAiClient {
    fn http_client() -> AppResult<reqwest::Client> {
        reqwest::Client::builder()
            .build()
            .map_err(|e| AppError::Ai(format!("http client: {e}")))
    }

    /// Effective endpoint (non-empty config base URL wins, trimmed of a
    /// trailing slash so the `/chat/completions` suffix joins cleanly).
    fn endpoint(base_url: &str) -> String {
        let base = base_url.trim();
        let base = if base.is_empty() {
            DEFAULT_BASE_URL
        } else {
            base.trim_end_matches('/')
        };
        format!("{base}/chat/completions")
    }
}

/// Minimal request body: model + messages + stream only, so no provider
/// rejects an unexpected field.
fn build_request(model: &str, messages: Value) -> Value {
    json!({
        "model": model,
        "messages": messages,
        "stream": true,
    })
}

/// Convert history (system prompt first, then prior turns) + the new user
/// input into OpenAI message objects.
fn text_messages(history: &[AiMessage], user_input: &str) -> Value {
    let mut msgs: Vec<Value> = Vec::with_capacity(history.len() + 1);
    for m in history {
        let role = match m.role {
            AiRole::System => "system",
            AiRole::User => "user",
            AiRole::Assistant => "assistant",
        };
        msgs.push(json!({"role": role, "content": m.content}));
    }
    msgs.push(json!({"role": "user", "content": user_input}));
    Value::Array(msgs)
}

/// Vision message: fixed prompt + the region screenshot as a data URL.
/// `detail` is deliberately omitted -- providers reject null/empty values.
fn vision_messages(prompt: &str, png: &[u8]) -> Value {
    use base64::Engine as _;
    let data_url = format!(
        "data:image/png;base64,{}",
        base64::engine::general_purpose::STANDARD.encode(png)
    );
    json!([
        {"role": "system", "content": crate::ai::prompts::chat_system()},
        {"role": "user", "content": [
            {"type": "text", "text": prompt},
            {"type": "image_url", "image_url": {"url": data_url}},
        ]},
    ])
}

/// Effective vision model: the dedicated vision model wins, else the text
/// model (FEATURES 6.1.2: vision falls back to the main config when empty).
fn vision_model(config: &AiConfig) -> &str {
    if config.vision_model.trim().is_empty() {
        &config.text_model
    } else {
        &config.vision_model
    }
}
/// Run a streaming chat request with plain reqwest. On non-2xx the full
/// provider error body is surfaced. SSE chunks are parsed into text chunks.
async fn stream_request(
    http: &reqwest::Client,
    url: String,
    api_key: &str,
    model: &str,
    messages: Value,
) -> AppResult<ChunkStream> {
    let resp = http
        .post(&url)
        .bearer_auth(api_key)
        .json(&build_request(model, messages))
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        // Keep the message bounded -- provider bodies can be long.
        let trimmed: String = body.chars().take(600).collect();
        return Err(AppError::Ai(format!("HTTP {status}: {trimmed}")));
    }
    Ok(Box::pin(parse_sse(resp.bytes_stream())))
}

/// Minimal SSE parser: buffers bytes, splits events on blank lines, reads
/// `data:` payloads, and yields `choices[0].delta.content` -- skipping
/// role-only chunks and the `[DONE]` sentinel.
fn parse_sse(
    stream: impl Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + 'static,
) -> impl Stream<Item = AppResult<String>> + Send {
    let mut buf: Vec<u8> = Vec::new();
    stream.flat_map(move |chunk| match chunk {
        Err(e) => {
            let errs: Vec<AppResult<String>> =
                vec![Err(AppError::Ai(e.to_string()))];
            futures_util::stream::iter(errs)
        }
        Ok(bytes) => {
            buf.extend_from_slice(&bytes);
            let mut texts: Vec<AppResult<String>> = Vec::new();
            loop {
                // Find the event terminator "\n\n".
                let Some(sep) = find_subslice(&buf, b"\n\n") else {
                    break;
                };
                let event: Vec<u8> = buf.drain(..sep).collect();
                buf.drain(..2); // consume the separator
                if let Some(text) = parse_event(&event) {
                    texts.push(Ok(text));
                }
            }
            futures_util::stream::iter(texts)
        }
    })
}

/// Locate `needle` inside `haystack`; returns the byte index or None.
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}

/// Parse one SSE event into a text chunk (None for role-only / `[DONE]` /
/// non-content events).
fn parse_event(event: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(event);
    let data = text
        .lines()
        .find_map(|l| l.strip_prefix("data:").map(str::trim))
        .unwrap_or("");
    if data.is_empty() || data == "[DONE]" {
        return None;
    }
    let value: Value = serde_json::from_str(data).ok()?;
    value
        .get("choices")?
        .as_array()?
        .first()?["delta"]["content"]
        .as_str()
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}


/// Real web search via a Bocha-compatible endpoint (FEATURES 6.2.3). The
/// configured base URL is used verbatim when non-empty (any provider with a
/// Bocha-style `web-search` API), otherwise the Bocha default. Returns the
/// top results formatted for the model to read: numbered name / link /
/// snippet.
pub async fn web_search(base_url: &str, api_key: &str, query: &str) -> AppResult<String> {
    let http = OpenAiClient::http_client()?;
    web_search_at(&http, search_endpoint(base_url), api_key, query).await
}

/// Resolve the web-search endpoint: empty config -> Bocha default; otherwise
/// the configured value is used as the full endpoint URL (trimmed of a
/// trailing slash).
fn search_endpoint(base_url: &str) -> String {
    let base = base_url.trim();
    if base.is_empty() {
        BOCHA_ENDPOINT.to_string()
    } else {
        base.trim_end_matches('/').to_string()
    }
}

/// Responses API endpoint (built-in web search, FEATURES 6.2.3): the base
/// URL is used as-is minus a trailing slash / `/v1` suffix (a chat-completions
/// convention some providers use), then `/responses` is appended.
fn responses_endpoint(base_url: &str) -> String {
    let base = base_url.trim();
    let base = if base.is_empty() {
        "https://api.openai.com"
    } else {
        base.trim_end_matches('/')
    };
    let base = base.strip_suffix("/v1").unwrap_or(base);
    format!("{base}/responses")
}

/// Responses API body for built-in web search: the first system message
/// becomes `instructions` (the API's system slot), the rest of the history is
/// converted to input items, and the `web_search` tool is forced so the
/// server executes the search and answers from the results.
fn responses_body(model: &str, history: &[AiMessage], user_input: &str) -> Value {
    let mut instructions = String::new();
    let mut items: Vec<Value> = Vec::new();
    for m in history {
        match m.role {
            AiRole::System => {
                // Merge multiple system messages into the single
                // instructions slot.
                if !instructions.is_empty() {
                    instructions.push('\n');
                }
                instructions.push_str(&m.content);
            }
            AiRole::User => items.push(json!({"role": "user", "content": m.content})),
            AiRole::Assistant => {
                items.push(json!({"role": "assistant", "content": m.content}))
            }
        }
    }
    items.push(json!({"role": "user", "content": user_input}));
    json!({
        "model": model,
        "instructions": instructions,
        "input": items,
        "tools": [{"type": "web_search"}],
        "tool_choice": {"type": "web_search"},
        "stream": true,
    })
}

/// Run a streaming Responses API request (built-in web search). The protocol
/// is semantic SSE events (no `[DONE]`): text deltas come from
/// `response.output_text.delta`, the stream ends with
/// `response.completed` / `response.incomplete` / `response.failed`.
async fn responses_stream_request(
    http: &reqwest::Client,
    url: String,
    api_key: &str,
    body: Value,
) -> AppResult<ChunkStream> {
    let resp = http
        .post(&url)
        .bearer_auth(api_key)
        .json(&body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        let trimmed: String = text.chars().take(600).collect();
        return Err(AppError::Ai(format!("HTTP {status}: {trimmed}")));
    }
    Ok(Box::pin(parse_responses_sse(resp.bytes_stream())))
}

/// SSE parser for the Responses API: same event framing as chat completions
/// (`data:` payloads split on blank lines), but the payload carries a `type`
/// discriminator -- only `response.output_text.delta` yields text, and
/// `response.failed` surfaces its error message.
fn parse_responses_sse(
    stream: impl Stream<Item = Result<bytes::Bytes, reqwest::Error>> + Send + 'static,
) -> impl Stream<Item = AppResult<String>> + Send {
    let mut buf: Vec<u8> = Vec::new();
    stream.flat_map(move |chunk| match chunk {
        Err(e) => futures_util::stream::iter(vec![Err(AppError::Ai(e.to_string()))]),
        Ok(bytes) => {
            buf.extend_from_slice(&bytes);
            let mut texts: Vec<AppResult<String>> = Vec::new();
            loop {
                let Some(sep) = find_subslice(&buf, b"\n\n") else {
                    break;
                };
                let event: Vec<u8> = buf.drain(..sep).collect();
                buf.drain(..2); // consume the separator
                match parse_responses_event(&event) {
                    Some(Ok(text)) => texts.push(Ok(text)),
                    Some(Err(e)) => {
                        texts.push(Err(e));
                        return futures_util::stream::iter(texts);
                    }
                    None => {}
                }
            }
            futures_util::stream::iter(texts)
        }
    })
}

/// Parse one Responses API event: `response.output_text.delta` -> text;
/// `response.failed` -> error; anything else is ignored.
fn parse_responses_event(event: &[u8]) -> Option<AppResult<String>> {
    let text = String::from_utf8_lossy(event);
    let data = text
        .lines()
        .find_map(|l| l.strip_prefix("data:").map(str::trim))
        .unwrap_or("");
    if data.is_empty() {
        return None;
    }
    let value: Value = serde_json::from_str(data).ok()?;
    match value["type"].as_str()? {
        "response.output_text.delta" => {
            let delta = value["delta"].as_str().unwrap_or("");
            if delta.is_empty() {
                None
            } else {
                Some(Ok(delta.to_string()))
            }
        }
        "response.failed" => {
            let message = value["error"]["message"]
                .as_str()
                .unwrap_or("responses call failed");
            Some(Err(AppError::Ai(message.to_string())))
        }
        _ => None,
    }
}

/// Built-in web search (FEATURES 6.2.3): streams a Responses API call with
/// the `web_search` tool forced, so the provider runs the search server-side
/// and the model answers with citations. `history` already carries the
/// search system prompt as its first (system) message.
pub async fn web_search_builtin(
    base_url: &str,
    api_key: &str,
    model: &str,
    history: &[AiMessage],
    query: &str,
) -> AppResult<ChunkStream> {
    let http = OpenAiClient::http_client()?;
    let url = responses_endpoint(base_url);
    let body = responses_body(model, history, query);
    responses_stream_request(&http, url, api_key, body).await
}

/// `web_search` against a specific endpoint (parameterized for tests).
async fn web_search_at(
    http: &reqwest::Client,
    endpoint: String,
    api_key: &str,
    query: &str,
) -> AppResult<String> {
    let resp = http
        .post(&endpoint)
        .bearer_auth(api_key)
        .json(&json!({
            "query": query,
            "freshness": "noLimit",
            "summary": true,
            "count": 8,
        }))
        .timeout(WEB_SEARCH_TIMEOUT)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        let trimmed: String = body.chars().take(600).collect();
        return Err(AppError::Ai(format!("HTTP {status}: {trimmed}")));
    }
    let value: Value = resp.json().await?;
    let pages = value["data"]["webPages"]["value"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    if pages.is_empty() {
        return Err(AppError::Ai("web search returned no results".into()));
    }
    let mut out = String::new();
    for (i, page) in pages.iter().enumerate() {
        let name = page["name"].as_str().unwrap_or("(无标题)");
        let url = page["url"].as_str().unwrap_or("");
        let snippet = page["snippet"].as_str().unwrap_or("");
        out.push_str(&format!(
            "{}. {name}\n   链接: {url}\n   摘要: {snippet}\n",
            i + 1
        ));
    }
    Ok(out)
}

impl AiClient for OpenAiClient {
    fn stream_chat(
        &self,
        config: &AiConfig,
        history: &[AiMessage],
        user_input: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send {
        async move {
            let http = Self::http_client()?;
            let messages = text_messages(history, user_input);
            let url = Self::endpoint(&config.base_url);
            stream_request(&http, url, &config.api_key, &config.text_model, messages).await
        }
    }

    fn stream_vision(
        &self,
        config: &AiConfig,
        png: &[u8],
        prompt: &str,
    ) -> impl Future<Output = AppResult<ChunkStream>> + Send {
        async move {
            let http = Self::http_client()?;
            let base_url = config
                .vision_base_url
                .as_deref()
                .unwrap_or(&config.base_url);
            let api_key = config.vision_api_key.as_deref().unwrap_or(&config.api_key);
            let messages = vision_messages(prompt, png);
            let url = Self::endpoint(base_url);
            stream_request(&http, url, api_key, vision_model(config), messages).await
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    /// Serve one HTTP response on a loopback port. Returns the endpoint and a
    /// receiver for the raw request text the client sent.
    async fn mock_server(
        status_line: &'static str,
        body: &'static str,
    ) -> (String, tokio::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let req = read_request(&mut sock).await;
            let _ = tx.send(req).await;
            let resp = format!(
                "HTTP/1.1 {status_line}\r\nContent-Type: application/json\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = sock.write_all(resp.as_bytes()).await;
        });
        (format!("http://127.0.0.1:{port}/v1/web-search"), rx)
    }

    /// Read the full HTTP request (headers + Content-Length body).
    async fn read_request(sock: &mut TcpStream) -> String {
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = sock.read(&mut chunk).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            if let Some(sep) = find_subslice(&buf, b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&buf[..sep]).to_string();
                let len = head
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if buf.len() >= sep + 4 + len {
                    break;
                }
            }
        }
        String::from_utf8_lossy(&buf).to_string()
    }

    #[test]
    fn search_endpoint_resolves_default_and_custom() {
        // Empty config -> Bocha default.
        assert_eq!(search_endpoint(""), BOCHA_ENDPOINT);
        assert_eq!(search_endpoint("  "), BOCHA_ENDPOINT);
        // Custom provider: used verbatim, trailing slash trimmed.
        assert_eq!(
            search_endpoint("https://example.com/v1/web-search"),
            "https://example.com/v1/web-search"
        );
        assert_eq!(
            search_endpoint("https://example.com/v1/web-search/"),
            "https://example.com/v1/web-search"
        );
    }

    #[test]
    fn responses_endpoint_strips_v1_and_appends_responses() {
        assert_eq!(
            responses_endpoint(""),
            "https://api.openai.com/responses"
        );
        assert_eq!(
            responses_endpoint("https://api.deepseek.com"),
            "https://api.deepseek.com/responses"
        );
        assert_eq!(
            responses_endpoint("https://api.deepseek.com/v1"),
            "https://api.deepseek.com/responses"
        );
        assert_eq!(
            responses_endpoint("https://api.deepseek.com/v1/"),
            "https://api.deepseek.com/responses"
        );
    }

    #[test]
    fn responses_body_uses_instructions_and_forces_web_search() {
        let history = vec![
            AiMessage {
                id: -1,
                thread_id: -1,
                role: AiRole::System,
                content: "你正在执行联网搜索。".into(),
                created_at: String::new(),
            },
            AiMessage {
                id: -1,
                thread_id: -1,
                role: AiRole::User,
                content: "之前的问题".into(),
                created_at: String::new(),
            },
        ];
        let body = responses_body("deepseek-v4-flash", &history, "量子计算");
        assert_eq!(body["model"], "deepseek-v4-flash");
        assert_eq!(body["instructions"], "你正在执行联网搜索。");
        assert_eq!(body["stream"], true);
        assert_eq!(body["tools"][0]["type"], "web_search");
        assert_eq!(body["tool_choice"]["type"], "web_search");
        let items = body["input"].as_array().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0]["role"], "user");
        assert_eq!(items[0]["content"], "之前的问题");
        assert_eq!(items[1]["role"], "user");
        assert_eq!(items[1]["content"], "量子计算");
    }

    /// Serve one Responses-style SSE stream and capture the raw request.
    async fn mock_responses_server(
        events: &'static str,
        status: &'static str,
    ) -> (String, tokio::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.unwrap();
            let req = read_request(&mut sock).await;
            let _ = tx.send(req).await;
            let resp = format!(
                "HTTP/1.1 {status}\r\nContent-Type: text/event-stream\r\n\
                 Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                events.len(),
                events
            );
            let _ = sock.write_all(resp.as_bytes()).await;
        });
        (format!("http://127.0.0.1:{port}/v1"), rx)
    }

    #[tokio::test]
    async fn web_search_builtin_streams_responses_deltas() {
        let events = r#"data: {"type":"response.created"}

data: {"type":"response.output_text.delta","delta":"量子"}

data: {"type":"response.output_text.delta","delta":"计算要点"}

data: {"type":"response.completed"}

"#;
        let (base, mut req_rx) = mock_responses_server(events, "200 OK").await;
        let history = [AiMessage {
            id: -1,
            thread_id: -1,
            role: AiRole::System,
            content: "你正在执行联网搜索。".into(),
            created_at: String::new(),
        }];
        let mut stream = web_search_builtin(&base, "test-key", "deepseek-v4-flash", &history, "量子")
            .await
            .unwrap();
        let mut out = String::new();
        while let Some(chunk) = stream.next().await {
            out.push_str(&chunk.unwrap());
        }
        assert_eq!(out, "量子计算要点");

        // Request shape: /responses path (v1 stripped) + forced web_search.
        let req = req_rx.recv().await.unwrap();
        assert!(req.starts_with("POST /responses HTTP/1.1"), "{req}");
        assert!(req_lower(&req).contains("authorization: bearer test-key"));
        assert!(req.contains("\"tools\":[{\"type\":\"web_search\"}]"), "{req}");
        assert!(req.contains("\"tool_choice\":{\"type\":\"web_search\"}"), "{req}");
        assert!(req.contains("\"instructions\":\"你正在执行联网搜索。\""), "{req}");
    }

    #[tokio::test]
    async fn web_search_builtin_surfaces_failed_event_and_http_error() {
        // Semantic `response.failed` event -> error with its message.
        let events = r#"data: {"type":"response.failed","error":{"message":"搜索服务不可用"}}

"#;
        let (base, _rx) = mock_responses_server(events, "200 OK").await;
        let mut stream = web_search_builtin(&base, "k", "m", &[], "q").await.unwrap();
        let err = stream.next().await.unwrap().unwrap_err();
        assert!(err.to_string().contains("搜索服务不可用"), "{err}");

        // Non-2xx -> full error body.
        let (base2, _rx) =
            mock_responses_server(r#"{"error":"model not found"}"#, "404 Not Found").await;
        let err2 = match web_search_builtin(&base2, "k", "m", &[], "q").await {
            Err(e) => e,
            Ok(_) => panic!("expected HTTP error"),
        };
        assert!(err2.to_string().contains("404"), "{err2}");
        assert!(err2.to_string().contains("model not found"), "{err2}");
    }

    #[test]
    fn vision_messages_embed_png_as_data_url_without_detail() {
        let png = vec![0x89, 0x50, 0x4e, 0x47, 1, 2, 3];
        let msgs = vision_messages("请识别图片", &png);
        let arr = msgs.as_array().unwrap();
        assert_eq!(arr.len(), 2);
        assert_eq!(arr[0]["role"], "system");
        assert!(arr[0]["content"].as_str().unwrap().contains("AI 助手"));
        assert_eq!(arr[1]["role"], "user");
        let parts = arr[1]["content"].as_array().unwrap();
        assert_eq!(parts[0]["type"], "text");
        assert_eq!(parts[0]["text"], "请识别图片");
        assert_eq!(parts[1]["type"], "image_url");
        let url = parts[1]["image_url"]["url"].as_str().unwrap();
        assert!(url.starts_with("data:image/png;base64,"), "{url}");
        // The PNG bytes are base64-encoded verbatim: 89 50 4e 47 01 02 03
        // -> iVBORwECAw==.
        assert_eq!(url, "data:image/png;base64,iVBORwECAw==");
        // `detail` must be omitted entirely (providers reject null/empty).
        assert!(!serde_json::to_string(&msgs).unwrap().contains("detail"));
    }

    #[test]
    fn vision_model_falls_back_to_text_model_when_empty() {
        let cfg = AiConfig {
            text_model: "text-m".into(),
            vision_model: String::new(),
            ..Default::default()
        };
        assert_eq!(vision_model(&cfg), "text-m");
        let cfg2 = AiConfig {
            text_model: "text-m".into(),
            vision_model: "  vision-m  ".into(),
            ..Default::default()
        };
        assert_eq!(vision_model(&cfg2), "  vision-m  ");
    }

    #[tokio::test]
    async fn stream_vision_streams_chunks_and_sends_data_url() {
        let events = r#"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"delta":{"role":"assistant"},"index":0}]}

data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"delta":{"content":"识别"},"index":0}]}

data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"delta":{"content":"结果"},"index":0}]}

data: [DONE]

"#;
        let (base, mut req_rx) = mock_responses_server(events, "200 OK").await;
        let cfg = AiConfig {
            api_key: "vision-key".into(),
            base_url: base.clone(),
            text_model: "text-m".into(),
            vision_model: "vision-m".into(),
            vision_base_url: Some(base.clone()),
            vision_api_key: Some("vision-key".into()),
            ..Default::default()
        };
        let client = OpenAiClient;
        let mut stream = client
            .stream_vision(&cfg, &[1u8, 2, 3], "请识别")
            .await
            .unwrap();
        let mut out = String::new();
        while let Some(chunk) = stream.next().await {
            out.push_str(&chunk.unwrap());
        }
        assert_eq!(out, "识别结果");

        // Request shape: /v1/chat/completions + the vision model + the PNG
        // as a data URL (no `detail` field anywhere).
        let req = req_rx.recv().await.unwrap();
        assert!(req.starts_with("POST /v1/chat/completions HTTP/1.1"), "{req}");
        assert!(req_lower(&req).contains("authorization: bearer vision-key"));
        assert!(req.contains("\"model\":\"vision-m\""), "{req}");
        assert!(req.contains("data:image/png;base64,AQID"), "{req}");
        assert!(!req.contains("detail"), "{req}");
    }

    #[tokio::test]
    async fn stream_vision_uses_vision_config_fallbacks() {
        // No vision model / url / key: falls back to the text config.
        let events = r#"data: {"id":"c","object":"chat.completion.chunk","created":1,"model":"m","choices":[{"delta":{"content":"ok"},"index":0}]}

data: [DONE]

"#;
        let (base, mut req_rx) = mock_responses_server(events, "200 OK").await;
        let cfg = AiConfig {
            api_key: "main-key".into(),
            base_url: base.clone(),
            text_model: "text-m".into(),
            vision_model: String::new(),
            vision_base_url: None,
            vision_api_key: None,
            ..Default::default()
        };
        let client = OpenAiClient;
        let mut stream = client.stream_vision(&cfg, &[9u8], "p").await.unwrap();
        let mut out = String::new();
        while let Some(chunk) = stream.next().await {
            out.push_str(&chunk.unwrap());
        }
        assert_eq!(out, "ok");
        let req = req_rx.recv().await.unwrap();
        assert!(req.contains("\"model\":\"text-m\""), "{req}");
        assert!(req_lower(&req).contains("authorization: bearer main-key"));
    }

    /// Lowercased request text (helper for bearer assertions).
    fn req_lower(req: &str) -> String {
        req.to_lowercase()
    }

    #[tokio::test]
    async fn web_search_formats_bocha_results() {        let body = r#"{"code":200,"data":{"webPages":{"value":[
            {"name":"Rust 官网","url":"https://www.rust-lang.org/","snippet":"Rust 是一门系统编程语言"},
            {"name":"Rust 中文社区","url":"https://rustcc.cn/","snippet":"Rust 中文学习资源"}
        ]}}}"#;
        let (endpoint, mut req_rx) = mock_server("200 OK", body).await;
        let http = OpenAiClient::http_client().unwrap();
        let out = web_search_at(&http, endpoint, "test-key", "rust 语言").await.unwrap();
        assert!(out.contains("Rust 官网"));
        assert!(out.contains("https://www.rust-lang.org/"));
        assert!(out.contains("Rust 中文社区"));
        assert!(out.contains("摘要:"));

        // Request shape: bearer auth + query body.
        let req_text = req_rx.recv().await.unwrap();
        let req_lower = req_text.to_lowercase();
        assert!(req_lower.contains("authorization: bearer test-key"), "{req_text}");
        assert!(req_text.contains("\"query\":\"rust 语言\""), "{req_text}");
        assert!(req_text.contains("\"count\":8"), "{req_text}");
        assert!(req_text.contains("\"freshness\":\"noLimit\""), "{req_text}");
    }

    #[tokio::test]
    async fn web_search_surfaces_non_2xx_body() {
        let (endpoint, _rx) = mock_server(
            "401 Unauthorized",
            r#"{"code":401,"msg":"API Key 无效"}"#,
        )
        .await;
        let http = OpenAiClient::http_client().unwrap();
        let err = web_search_at(&http, endpoint, "bad-key", "q").await.unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("401"), "{msg}");
        assert!(msg.contains("API Key 无效"), "{msg}");
    }

    #[tokio::test]
    async fn web_search_empty_results_is_an_error() {
        let (endpoint, _rx) =
            mock_server("200 OK", r#"{"code":200,"data":{"webPages":{"value":[]}}}"#).await;
        let http = OpenAiClient::http_client().unwrap();
        let err = web_search_at(&http, endpoint, "k", "q").await.unwrap_err();
        assert!(err.to_string().contains("no results"), "{err}");
    }
}
