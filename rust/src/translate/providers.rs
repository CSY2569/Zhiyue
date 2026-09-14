//! Translation providers for bilingual reading (M7, plan §4).
//!
//! Two backends behind one enum:
//! - **DeepL**: `/v2/translate` with `tag_handling=xml` + `ignore_tags` so
//!   formula placeholders ride through untouched; glossaries are created
//!   through the API and their ids persisted per language pair (plan §4.4);
//! - **LLM** (generic OpenAI-compatible, or the AI settings' own config):
//!   strict-alignment JSON batches `[{"i","t"}]` with per-segment re-request
//!   for missing / misaligned indices (plan §4.2).
//!
//! Both go through [post_with_retry]: 429/5xx retry with exponential
//! backoff + `Retry-After`, 4xx fail fast (plan §4.6). Untrusted book text
//! is wrapped in `<text>` tags before entering any prompt (plan §4.8, the
//! `wrap_input` pattern from api.rs).

use std::time::Duration;

use serde_json::{json, Value};

use crate::error::{AppError, AppResult};
use crate::models::ai::AiConfig;
use crate::models::translate::{FormulaRegion, TranslationConfig, TranslationProviderKind};

/// Segments per provider request (page-level batches are chunked to this).
const MAX_BATCH: usize = 20;
/// Retries on 429/5xx (plan §4.6: 限流 + 退避重试).
const MAX_RETRIES: u32 = 3;

/// DeepL free tier endpoint (keys ending in `:fx`).
const DEEPL_FREE_BASE: &str = "https://api-free.deepl.com";
/// DeepL pro tier endpoint.
const DEEPL_PRO_BASE: &str = "https://api.deepl.com";

// =============================================================================
// Segment types
// =============================================================================

/// One paragraph to translate, with its inline formula regions.
#[derive(Debug, Clone)]
pub struct Segment {
    pub text: String,
    /// Inline formula regions of this paragraph (whole-paragraph formulas
    /// are filtered out upstream and never reach a provider).
    pub formulas: Vec<FormulaRegion>,
}

/// One translated segment: the text keeps `⟨…MATH_n⟩` tokens in place
/// (consumers substitute them with the original text or an image);
/// `formula_ok[i]` says whether the i-th formula's token survived the
/// round-trip unchanged and exactly once (plan §4.3); `failed` marks a
/// segment the provider could not translate after its retry rounds (the
/// original text is carried back for display).
#[derive(Debug, Clone)]
pub struct SegmentResult {
    pub text: String,
    pub formula_ok: Vec<bool>,
    pub failed: bool,
}

/// Context carried with every batch (plan §4.4: 书名与相邻段落 + 术语表).
#[derive(Debug, Clone, Default)]
pub struct BatchContext {
    pub book_title: String,
    /// Effective target language (display name, e.g. "中文").
    pub target_lang: String,
    /// "auto" or a specific language display name / code.
    pub source_lang: String,
    pub prev_paragraph: String,
    pub next_paragraph: String,
    /// Glossary term pairs applicable to this request.
    pub glossary: Vec<(String, String)>,
}

// =============================================================================
// Provider selection
// =============================================================================

/// The active translation backend, built from the translation config (the
/// `ReuseAi` variant reads the AI settings' OpenAI-compatible endpoint).
pub enum Provider {
    DeepL { base_url: String, api_key: String },
    Llm { base_url: String, api_key: String, model: String },
}

pub fn provider_from_config(
    config: &TranslationConfig,
    ai: &AiConfig,
) -> AppResult<Provider> {
    let key_of = |s: &Option<String>| -> AppResult<String> {
        s.as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .ok_or_else(|| AppError::Ai("翻译服务未配置 API Key".into()))
    };
    match config.provider {
        TranslationProviderKind::DeepL => {
            let api_key = key_of(&config.api_key)?;
            let base_url = config
                .base_url
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| s.trim_end_matches('/').to_string())
                .unwrap_or_else(|| {
                    // DeepL convention: free keys end with ":fx".
                    if api_key.ends_with(":fx") {
                        DEEPL_FREE_BASE.to_string()
                    } else {
                        DEEPL_PRO_BASE.to_string()
                    }
                });
            Ok(Provider::DeepL { base_url, api_key })
        }
        TranslationProviderKind::OpenAiCompat => {
            let base_url = config
                .base_url
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(|s| s.trim_end_matches('/').to_string())
                .ok_or_else(|| AppError::Ai("翻译服务未配置 API 地址".into()))?;
            let api_key = key_of(&config.api_key)?;
            let model = config
                .model
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .ok_or_else(|| AppError::Ai("翻译服务未配置模型".into()))?;
            Ok(Provider::Llm {
                base_url,
                api_key,
                model,
            })
        }
        TranslationProviderKind::ReuseAi => {
            if ai.api_key.trim().is_empty() || ai.text_model.trim().is_empty() {
                return Err(AppError::Ai("AI 设置未配置,无法复用为翻译服务".into()));
            }
            let base_url = if ai.base_url.trim().is_empty() {
                "https://api.openai.com/v1".to_string()
            } else {
                ai.base_url.trim().trim_end_matches('/').to_string()
            };
            Ok(Provider::Llm {
                base_url,
                api_key: ai.api_key.trim().to_string(),
                model: config
                    .model
                    .as_deref()
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| ai.text_model.trim().to_string()),
            })
        }
    }
}

impl Provider {
    /// Translates a batch of segments, strictly aligned by index. Chunks to
    /// [MAX_BATCH] per request; a failed chunk fails the whole call (the
    /// pipeline marks the page's segments failed).
    pub async fn translate_segments(
        &self,
        segments: &[Segment],
        ctx: &BatchContext,
    ) -> AppResult<Vec<SegmentResult>> {
        let mut out = Vec::with_capacity(segments.len());
        for chunk in segments.chunks(MAX_BATCH) {
            out.extend(self.translate_chunk(chunk, ctx).await?);
        }
        Ok(out)
    }

    async fn translate_chunk(
        &self,
        segments: &[Segment],
        ctx: &BatchContext,
    ) -> AppResult<Vec<SegmentResult>> {
        match self {
            Provider::DeepL { base_url, api_key } => {
                deepl_translate(base_url, api_key, segments, ctx).await
            }
            Provider::Llm {
                base_url,
                api_key,
                model,
            } => llm_translate(base_url, api_key, model, segments, ctx).await,
        }
    }
}

// =============================================================================
// Placeholder protection (plan §4.3)
// =============================================================================

/// One formula substitution: the token that replaces the formula text while
/// in transit and the original text to restore afterwards.
#[derive(Debug, Clone)]
pub struct Placeholder {
    pub token: String,
    pub source_text: String,
}

/// Random-ish prefix baked into every token so a book cannot forge
/// placeholders by literally containing `⟨MATH_0⟩` (plan §4.3 防伪造).
/// Per-request random keeps it unpredictable.
pub fn token_prefix() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    format!("F{:x}{:x}", nanos, std::process::id())
}

/// Substitutes a segment's inline formulas with provider-safe placeholders.
/// LLM path: `⟨{prefix}-MATH_{i}⟩` tokens; DeepL path: XML ignore-tag pairs
/// `<m{i}>…</m{i}>` (the source text is XML-escaped first). Lookalike
/// tokens already present in the source are neutralized by swapping `⟨`
/// for `〈` (the LLM path) before substitution.
///
/// Formula regions whose `source_text` is not found in the text stay inline
/// (untranslated formula text; no token, no validation).
pub fn protect_segment(
    text: &str,
    formulas: &[FormulaRegion],
    prefix: &str,
    xml_tags: bool,
) -> (String, Vec<Placeholder>) {
    let mut text = text.to_string();
    if !xml_tags {
        // Anti-forgery: neutralize existing lookalike tokens first.
        text = text.replace('⟨', "〈");
    } else {
        text = xml_escape(&text);
    }
    let mut subs = Vec::new();
    for (i, f) in formulas.iter().enumerate() {
        let src = f.source_text.trim();
        if src.is_empty() || !text.contains(src) {
            continue;
        }
        let token = format!("⟨{prefix}-MATH_{i}⟩");
        let needle = if xml_tags {
            format!("<m{i}>{}</m{i}>", xml_escape(src))
        } else {
            token.clone()
        };
        text = text.replace(src, &needle);
        subs.push(Placeholder {
            token,
            source_text: src.to_string(),
        });
    }
    (text, subs)
}

/// Puts the validated placeholders back (formula text travels in the token;
/// consumers substitute). Returns the restored text plus, per substitution,
/// whether the token appeared exactly once and unchanged (plan §4.3 回填校验).
/// Failed validations fall back to the original formula text and flag false.
pub fn restore_placeholders(text: &str, subs: &[Placeholder]) -> (String, Vec<bool>) {
    let mut text = text.to_string();
    let mut ok = Vec::with_capacity(subs.len());
    for sub in subs {
        let count = text.matches(&sub.token).count();
        if count == 1 {
            // The token stays in the text; consumers substitute the formula.
            ok.push(true);
        } else {
            // Mangled / duplicated / dropped: restore the original formula
            // text so the pane shows something honest, flagged for review.
            text = text.replace(&sub.token, &sub.source_text);
            ok.push(false);
        }
    }
    (text, ok)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

// =============================================================================
// Shared retry transport
// =============================================================================

/// POST JSON with 429/5xx backoff (exponential, `Retry-After` respected),
/// ≤ [MAX_RETRIES] retries; other statuses fail fast with the body shown.
pub(crate) async fn post_with_retry(
    url: &str,
    headers: &[(&str, &str)],
    body: &Value,
) -> AppResult<reqwest::Response> {
    let client = crate::ai::OpenAiClient::http_client()?;
    let mut attempt = 0u32;
    loop {
        let mut req = client.post(url).json(body);
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
        let resp = req.send().await?;
        let status = resp.status();
        if status.is_success() {
            return Ok(resp);
        }
        if (status.as_u16() == 429 || status.is_server_error()) && attempt < MAX_RETRIES {
            let retry_after = resp
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.trim().parse::<u64>().ok())
                .map(Duration::from_secs)
                .unwrap_or_else(|| Duration::from_millis(500 * 2u64.pow(attempt)));
            tracing::warn!(%status, attempt, ?retry_after, "translation provider retry");
            tokio::time::sleep(retry_after).await;
            attempt += 1;
            continue;
        }
        let text = resp.text().await.unwrap_or_default();
        let trimmed: String = text.chars().take(600).collect();
        return Err(AppError::Ai(format!("HTTP {status}: {trimmed}")));
    }
}

// =============================================================================
// DeepL
// =============================================================================

/// Display language name -> DeepL code (plan §8: 界面显示名 ↔ 代码映射).
pub fn deepl_lang_code(display: &str) -> Option<&'static str> {
    match display.trim() {
        "中文" | "汉语" | "Chinese" => Some("ZH"),
        "英文" | "英语" | "English" => Some("EN-US"),
        "日文" | "日语" | "Japanese" => Some("JA"),
        "韩文" | "韩语" | "Korean" => Some("KO"),
        "法文" | "法语" | "French" => Some("FR"),
        "德文" | "德语" | "German" => Some("DE"),
        "西班牙文" | "西班牙语" | "Spanish" => Some("ES"),
        "葡萄牙文" | "葡萄牙语" | "Portuguese" => Some("PT-BR"),
        "意大利文" | "意大利语" | "Italian" => Some("IT"),
        "俄文" | "俄语" | "Russian" => Some("RU"),
        _ => None,
    }
}

async fn deepl_translate(
    base_url: &str,
    api_key: &str,
    segments: &[Segment],
    ctx: &BatchContext,
) -> AppResult<Vec<SegmentResult>> {
    let target = deepl_lang_code(&ctx.target_lang).ok_or_else(|| {
        AppError::Ai(format!("DeepL 不支持目标语言「{}」", ctx.target_lang))
    })?;
    // DeepL source_lang must be omitted for auto-detection.
    let source = if ctx.source_lang.trim().eq_ignore_ascii_case("auto")
        || ctx.source_lang.trim().is_empty()
    {
        None
    } else {
        deepl_lang_code(&ctx.source_lang).map(str::to_string)
    };

    // Formula protection as XML ignore-tag pairs.
    let prefix = token_prefix();
    let mut protected = Vec::with_capacity(segments.len());
    let mut all_subs = Vec::with_capacity(segments.len());
    let mut tag_names = Vec::new();
    for seg in segments {
        let (text, subs) = protect_segment(&seg.text, &seg.formulas, &prefix, true);
        for i in 0..subs.len() {
            tag_names.push(format!("m{i}"));
        }
        protected.push(text);
        all_subs.push(subs);
    }

    let mut body = json!({
        "text": protected,
        "target_lang": target,
        "tag_handling": "xml",
        "ignore_tags": tag_names,
    });
    if let Some(src) = &source {
        body["source_lang"] = json!(src);
    }
    // Glossary (plan §4.4): DeepL glossaries are per language pair and the
    // pair must match the request; auto-detection cannot carry one.
    if !ctx.glossary.is_empty() {
        if let (Some(src), Some(glossary_id)) = (
            source.as_deref(),
            deepl_glossary_id(base_url, api_key, target, ctx).await?,
        ) {
            body["glossary_id"] = json!(glossary_id);
            let _ = src;
        }
    }

    let resp = post_with_retry(
        &format!("{base_url}/v2/translate"),
        &[("Authorization", &format!("DeepL-Auth-Key {api_key}"))],
        &body,
    )
    .await?;
    let parsed: Value = resp.json().await?;
    let translations = parsed
        .get("translations")
        .and_then(Value::as_array)
        .ok_or_else(|| AppError::Ai("DeepL 响应缺少 translations".into()))?;
    if translations.len() != segments.len() {
        return Err(AppError::Ai(format!(
            "DeepL 数量不匹配: 发送 {} 段,返回 {} 段",
            segments.len(),
            translations.len()
        )));
    }

    let mut out = Vec::with_capacity(segments.len());
    for (i, t) in translations.iter().enumerate() {
        let mut text = t
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        // Map <mN>…</mN> pairs back to tokens (DeepL may escape the angles).
        for (j, sub) in all_subs[i].iter().enumerate() {
            let pair = format!("<m{j}>");
            let escaped_pair = format!("&lt;m{j}&gt;");
            let close = format!("</m{j}>");
            let escaped_close = format!("&lt;/m{j}&gt;");
            if text.contains(&pair) || text.contains(&escaped_pair) {
                // Replace everything between the pair markers with the token
                // (the ignored original text is not needed back).
                let open_tok = if text.contains(&pair) { pair } else { escaped_pair };
                let close_tok = if text.contains(&close) { close } else { escaped_close };
                while let Some(start) = text.find(&open_tok) {
                    if let Some(end_rel) = text[start + open_tok.len()..].find(&close_tok) {
                        let end = start + open_tok.len() + end_rel + close_tok.len();
                        text.replace_range(start..end, &sub.token);
                    } else {
                        break;
                    }
                }
            }
        }
        let (text, ok) = restore_placeholders(&text, &all_subs[i]);
        out.push(SegmentResult {
            text,
            formula_ok: ok,
            failed: false,
        });
    }
    Ok(out)
}

/// Resolves (creating on first use) the DeepL glossary id for the current
/// language pair + entries, persisted in the settings KV as
/// `deepl_glossary_{src}_{tgt}` with an entries hash for change detection
/// (plan §4.4: glossary 资源经 API 创建并持久化 glossary_id).
async fn deepl_glossary_id(
    base_url: &str,
    api_key: &str,
    target: &str,
    ctx: &BatchContext,
) -> AppResult<Option<String>> {
    if ctx.glossary.is_empty() {
        return Ok(None);
    }
    let Some(source) = deepl_lang_code(&ctx.source_lang) else {
        return Ok(None);
    };
    // Normalize EN-US style codes to the bare form DeepL glossaries expect
    // for English (EN-GB / EN-US both map to EN as a glossary language).
    let glossary_source = source.trim_end_matches("-US").trim_end_matches("-GB");
    let glossary_target = target.trim_end_matches("-US").trim_end_matches("-GB");
    if glossary_source == glossary_target {
        return Ok(None);
    }
    let mut entries = String::new();
    for (s, t) in &ctx.glossary {
        entries.push_str(&format!("{}\t{}\n", s.replace('\t', " "), t.replace('\t', " ")));
    }
    let entries_hash = crate::translate::source_hash(&[&entries]);
    let kv_key = format!("deepl_glossary_{glossary_source}_{glossary_target}");

    // Existing id + unchanged entries -> reuse.
    {
        let conn = crate::db::db();
        let raw: Option<String> = conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                rusqlite::params![kv_key],
                |row| row.get(0),
            )
            .ok();
        if let Some(raw) = raw {
            if let Ok(saved) = serde_json::from_str::<Value>(&raw) {
                if saved.get("hash").and_then(Value::as_str) == Some(entries_hash.as_str()) {
                    if let Some(id) = saved.get("id").and_then(Value::as_str) {
                        return Ok(Some(id.to_string()));
                    }
                }
            }
        }
    }

    // Create a new glossary resource (entries changed or none yet).
    let body = json!({
        "name": format!("rbwa-{glossary_source}-{glossary_target}"),
        "source_lang": glossary_source,
        "target_lang": glossary_target,
        "entries": entries,
        "entries_format": "tsv",
    });
    let resp = post_with_retry(
        &format!("{base_url}/v2/glossaries"),
        &[("Authorization", &format!("DeepL-Auth-Key {api_key}"))],
        &body,
    )
    .await?;
    let parsed: Value = resp.json().await?;
    let id = parsed
        .get("glossary_id")
        .and_then(Value::as_str)
        .ok_or_else(|| AppError::Ai("DeepL 术语表创建失败".into()))?
        .to_string();
    {
        let conn = crate::db::db();
        let _ = conn.execute(
            "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now')) \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = datetime('now')",
            rusqlite::params![
                kv_key,
                serde_json::to_string(&json!({"id": id, "hash": entries_hash})).unwrap()
            ],
        );
    }
    Ok(Some(id))
}

// =============================================================================
// LLM (OpenAI-compatible, non-streaming)
// =============================================================================

/// Injected into every prompt with the untrusted text (plan §4.8, mirrors
/// api.rs `wrap_untrusted_input`).
fn wrap_untrusted(text: &str) -> String {
    format!("<text>{text}</text>")
}

fn llm_system_prompt(ctx: &BatchContext) -> String {
    let mut s = format!(
        "你是专业书籍翻译引擎。把用户消息中每个编号段落的 <text> 内容翻译为「{}」，\
保持段落含义与语气，不要添加解释。",
        ctx.target_lang
    );
    if !ctx.glossary.is_empty() {
        s.push_str("\n术语表（必须遵守）：");
        for (src, tgt) in &ctx.glossary {
            s.push_str(&format!("\n- {src} → {tgt}"));
        }
    }
    if !ctx.book_title.is_empty() {
        s.push_str(&format!("\n参考上下文（不要翻译）：书名《{}》", ctx.book_title));
    }
    if !ctx.prev_paragraph.is_empty() {
        s.push_str(&format!("\n上一段（仅作上下文）：{}", ctx.prev_paragraph));
    }
    if !ctx.next_paragraph.is_empty() {
        s.push_str(&format!("\n下一段（仅作上下文）：{}", ctx.next_paragraph));
    }
    s.push_str(
        "\n严格规则：\n\
1. 形如 ⟨…⟩ 的占位符必须原样保留，不得翻译、改写、移动、复制或删除。\n\
2. 只输出 JSON 数组，形如 [{\"i\":0,\"t\":\"译文\"}]；每个输入编号恰好一项，不要输出其他任何内容。",
    );
    s
}

async fn llm_translate(
    base_url: &str,
    api_key: &str,
    model: &str,
    segments: &[Segment],
    ctx: &BatchContext,
) -> AppResult<Vec<SegmentResult>> {
    let prefix = token_prefix();
    let mut protected = Vec::with_capacity(segments.len());
    let mut all_subs = Vec::with_capacity(segments.len());
    for seg in segments {
        let (text, subs) = protect_segment(&seg.text, &seg.formulas, &prefix, false);
        protected.push(text);
        all_subs.push(subs);
    }

    let ask = |indices: &[usize]| -> Value {
        let items: Vec<Value> = indices
            .iter()
            .map(|&i| json!({"i": i, "text": wrap_untrusted(&protected[i])}))
            .collect();
        json!([{"role": "system", "content": llm_system_prompt(ctx)},
               {"role": "user", "content": json!({"segments": items}).to_string()}])
    };
    let call = |messages: Value| async move {
        let body = json!({"model": model, "messages": messages, "stream": false});
        let resp = post_with_retry(
            &format!("{base_url}/chat/completions"),
            &[("Authorization", &format!("Bearer {api_key}"))],
            &body,
        )
        .await?;
        let parsed: Value = resp.json().await?;
        parsed
            .get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .ok_or_else(|| AppError::Ai("LLM 响应缺少 choices[0].message.content".into()))
    };

    // Round 1: the whole chunk. Round 2/3: only the missing indices,
    // individually re-requested (plan §4.2 缺项/错位逐段重译).
    let mut results: Vec<Option<String>> = vec![None; segments.len()];
    let mut indices: Vec<usize> = (0..segments.len()).collect();
    for _round in 0..3 {
        if indices.is_empty() {
            break;
        }
        let content = call(ask(&indices)).await?;
        let pairs = parse_alignment(&content)
            .map_err(|e| AppError::Ai(format!("LLM 对齐解析失败: {e}")))?;
        let mut next = Vec::new();
        for &i in &indices {
            match pairs.get(&i) {
                Some(t) if !t.trim().is_empty() => results[i] = Some(t.clone()),
                _ => next.push(i),
            }
        }
        indices = next;
    }

    let mut out = Vec::with_capacity(segments.len());
    for (i, seg) in segments.iter().enumerate() {
        match &results[i] {
            Some(text) => {
                let (text, ok) = restore_placeholders(text, &all_subs[i]);
                out.push(SegmentResult {
                    text,
                    formula_ok: ok,
                    failed: false,
                });
            }
            None => {
                // Failed after retries: keep the source as-is so the
                // paragraph is visibly untranslated (status Failed).
                out.push(SegmentResult {
                    text: seg.text.clone(),
                    formula_ok: vec![false; all_subs[i].len()],
                    failed: true,
                });
            }
        }
    }
    Ok(out)
}

/// Parses the model's `[{"i":..,"t":..}]` answer. Accepts code fences and
/// surrounding prose; rejects duplicate/unknown indices (misalignment).
fn parse_alignment(
    content: &str,
) -> Result<std::collections::HashMap<usize, String>, String> {
    let start = content.find('[').ok_or("缺少 JSON 数组")?;
    let end = content.rfind(']').ok_or("缺少 JSON 数组结尾")?;
    let slice = &content[start..=end];
    let arr: Vec<Value> =
        serde_json::from_str(slice).map_err(|e| format!("JSON 解析: {e}"))?;
    let mut map = std::collections::HashMap::new();
    for item in arr {
        let i = item
            .get("i")
            .and_then(Value::as_i64)
            .ok_or("缺少 i 字段")?;
        let t = item
            .get("t")
            .and_then(Value::as_str)
            .ok_or("缺少 t 字段")?
            .to_string();
        if map.insert(i as usize, t).is_some() {
            return Err(format!("编号 {i} 重复"));
        }
    }
    Ok(map)
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::annotation::NormRect;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    fn formula(_placeholder_index: usize, source: &str) -> FormulaRegion {
        FormulaRegion {
            rect: NormRect { x: 0.1, y: 0.5, w: 0.2, h: 0.02 },
            image_path: None,
            source_text: source.into(),
            placeholder: String::new(),
        }
    }

    #[test]
    fn protect_and_restore_llm_tokens_roundtrip_exactly_once() {
        let text = "when ⟨F1-MATH_0⟩ is large, x2 +y diverges"; // lookalike forgery attempt
        let formulas = vec![formula(0, "x2 +y")];
        let prefix = "Fabc";
        let (protected, subs) = protect_segment(text, &formulas, prefix, false);
        // The forged token was neutralized; the real one substituted.
        assert!(protected.contains(&format!("⟨{prefix}-MATH_0⟩")), "{protected}");
        assert!(!protected.contains("⟨F1-MATH_0⟩"), "{protected}");
        assert_eq!(subs.len(), 1);
        assert_eq!(subs[0].source_text, "x2 +y");

        // Token survives exactly once -> ok, and stays in the text.
        let translated = format!("当 ⟨{prefix}-MATH_0⟩ 很大时发散");
        let (restored, ok) = restore_placeholders(&translated, &subs);
        assert_eq!(ok, vec![true]);
        assert!(restored.contains(&format!("⟨{prefix}-MATH_0⟩")));

        // Token dropped by the model -> backfill original + flag false.
        let (_restored, ok) = restore_placeholders("当它很大时发散", &subs);
        assert_eq!(ok, vec![false]);

        // Token duplicated by the model -> flag false, no leftover tokens.
        let dup = format!("当 ⟨{prefix}-MATH_0⟩ 与 ⟨{prefix}-MATH_0⟩ 都很大");
        let (restored, ok) = restore_placeholders(&dup, &subs);
        assert_eq!(ok, vec![false]);
        assert!(!restored.contains("MATH"));
    }

    #[test]
    fn protect_deepl_wraps_xml_ignore_tags() {
        let text = "for a < b and x2 +y holds";
        let formulas = vec![formula(0, "x2 +y")];
        let (protected, subs) = protect_segment(text, &formulas, "Fx", true);
        // Source XML-escaped, formula wrapped in an ignore-tag pair.
        assert!(protected.contains("<m0>x2 +y</m0>"), "{protected}");
        assert!(protected.contains("a &lt; b"), "{protected}");
        assert_eq!(subs.len(), 1);
    }

    #[test]
    fn parse_alignment_strips_fences_and_rejects_duplicates() {
        let ok = parse_alignment(r#"好的，结果是：
```json
[{"i":0,"t":"甲"},{"i":1,"t":"乙"}]
```"#);
        assert!(ok.is_ok());
        let map = ok.unwrap();
        assert_eq!(map.get(&0).map(String::as_str), Some("甲"));
        assert_eq!(map.get(&1).map(String::as_str), Some("乙"));

        assert!(parse_alignment(r#"[{"i":0,"t":"a"},{"i":0,"t":"b"}]"#).is_err());
        assert!(parse_alignment("no json here").is_err());
        // Missing t field -> error.
        assert!(parse_alignment(r#"[{"i":0}]"#).is_err());
    }

    #[test]
    fn deepl_lang_mapping() {
        assert_eq!(deepl_lang_code("中文"), Some("ZH"));
        assert_eq!(deepl_lang_code("英文"), Some("EN-US"));
        assert_eq!(deepl_lang_code("法文"), Some("FR"));
        assert_eq!(deepl_lang_code("世界语"), None);
    }

    #[test]
    fn provider_from_config_validates_inputs() {
        let mut tc = TranslationConfig::default();
        let ai = AiConfig::default();
        // ReuseAi without AI config errors clearly.
        assert!(provider_from_config(&tc, &ai).is_err());
        // DeepL without key errors.
        tc.provider = TranslationProviderKind::DeepL;
        assert!(provider_from_config(&tc, &ai).is_err());
        // DeepL free key picks the free endpoint.
        tc.api_key = Some("abc:fx".into());
        match provider_from_config(&tc, &ai).unwrap() {
            Provider::DeepL { base_url, .. } => assert_eq!(base_url, DEEPL_FREE_BASE),
            _ => panic!("expected deepl"),
        }
        // OpenAiCompat requires all three fields.
        tc.provider = TranslationProviderKind::OpenAiCompat;
        tc.api_key = None;
        assert!(provider_from_config(&tc, &ai).is_err());
        tc.base_url = Some("https://api.example.com/v1/".into());
        tc.api_key = Some("k".into());
        tc.model = Some("m".into());
        match provider_from_config(&tc, &ai).unwrap() {
            Provider::Llm { base_url, model, .. } => {
                assert_eq!(base_url, "https://api.example.com/v1");
                assert_eq!(model, "m");
            }
            _ => panic!("expected llm"),
        }
        // ReuseAi with a configured AI works; a translation-model override
        // wins, otherwise the AI settings' text model is used.
        let ai2 = AiConfig {
            api_key: "sk-1".into(),
            text_model: "deepseek-chat".into(),
            base_url: "https://api.deepseek.com/v1".into(),
            ..Default::default()
        };
        tc.provider = TranslationProviderKind::ReuseAi;
        tc.model = None;
        match provider_from_config(&tc, &ai2).unwrap() {
            Provider::Llm { base_url, model, .. } => {
                assert_eq!(base_url, "https://api.deepseek.com/v1");
                assert_eq!(model, "deepseek-chat");
            }
            _ => panic!("expected llm"),
        }
        tc.model = Some("translator-xl".into());
        match provider_from_config(&tc, &ai2).unwrap() {
            Provider::Llm { model, .. } => assert_eq!(model, "translator-xl"),
            _ => panic!("expected llm"),
        }
    }

    /// Serve N HTTP responses on a loopback port; returns the endpoint and a
    /// receiver for each raw request (openai.rs test pattern).
    async fn mock_server(
        responses: Vec<(&'static str, String)>,
    ) -> (String, tokio::sync::mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = tokio::sync::mpsc::channel(responses.len());
        tokio::spawn(async move {
            for (status_line, body) in responses {
                let Ok((mut sock, _)) = listener.accept().await else {
                    return;
                };
                let req = read_request(&mut sock).await;
                let _ = tx.send(req).await;
                let resp = format!(
                    "HTTP/1.1 {status_line}\r\nContent-Type: application/json\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes()).await;
            }
        });
        (format!("http://127.0.0.1:{port}"), rx)
    }

    async fn read_request(sock: &mut tokio::net::TcpStream) -> String {
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = sock.read(&mut chunk).await.unwrap();
            if n == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..n]);
            if let Some(sep) = buf
                .windows(4)
                .position(|w| w == b"\r\n\r\n")
            {
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

    fn ctx() -> BatchContext {
        BatchContext {
            book_title: "Test Book".into(),
            target_lang: "中文".into(),
            source_lang: "auto".into(),
            prev_paragraph: String::new(),
            next_paragraph: String::new(),
            glossary: Vec::new(),
        }
    }

    #[tokio::test]
    async fn llm_round2_refetches_missing_indices() {
        // Round 1 returns only index 0; round 2 (single-segment re-request)
        // must return index 1 -> both aligned.
        let (base, mut rx) = mock_server(vec![
            (
                "200 OK",
                r#"{"choices":[{"message":{"content":"[{\"i\":0,\"t\":\"第一段\"}]"}}]}"#.into(),
            ),
            (
                "200 OK",
                r#"{"choices":[{"message":{"content":"[{\"i\":1,\"t\":\"第二段\"}]"}}]}"#.into(),
            ),
        ])
        .await;
        let provider = Provider::Llm {
            base_url: format!("{base}/v1"),
            api_key: "k".into(),
            model: "m".into(),
        };
        let segments = vec![
            Segment { text: "one".into(), formulas: vec![] },
            Segment { text: "two".into(), formulas: vec![] },
        ];
        let out = provider.translate_segments(&segments, &ctx()).await.unwrap();
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].text, "第一段");
        assert_eq!(out[1].text, "第二段");
        // Both requests hit the chat endpoint with the auth header.
        let first = rx.recv().await.unwrap();
        assert!(first.contains("POST /v1/chat/completions"), "{first}");
        assert!(first.contains("Bearer k"), "{first}");
        assert!(first.contains("<text>one</text>"), "{first}");
        let second = rx.recv().await.unwrap();
        assert!(second.contains("<text>two</text>"), "{second}");
    }

    #[tokio::test]
    async fn llm_failed_after_retries_keeps_source() {
        // All three rounds fail to return index 0 -> segment stays source.
        let (base, _rx) = mock_server(vec![
            ("200 OK", r#"{"choices":[{"message":{"content":"[]"}}]}"#.into()),
            ("200 OK", r#"{"choices":[{"message":{"content":"[]"}}]}"#.into()),
            ("200 OK", r#"{"choices":[{"message":{"content":"[]"}}]}"#.into()),
        ])
        .await;
        let provider = Provider::Llm {
            base_url: format!("{base}/v1"),
            api_key: "k".into(),
            model: "m".into(),
        };
        let segments = vec![Segment { text: "keep me".into(), formulas: vec![] }];
        let out = provider.translate_segments(&segments, &ctx()).await.unwrap();
        assert_eq!(out[0].text, "keep me");
    }

    #[tokio::test]
    async fn llm_429_retries_then_succeeds() {
        let (base, _rx) = mock_server(vec![
            ("429 Too Many Requests", "{}".into()),
            (
                "200 OK",
                r#"{"choices":[{"message":{"content":"[{\"i\":0,\"t\":\"好\"}]"}}]}"#.into(),
            ),
        ])
        .await;
        let provider = Provider::Llm {
            base_url: format!("{base}/v1"),
            api_key: "k".into(),
            model: "m".into(),
        };
        let out = provider
            .translate_segments(&[Segment { text: "ok".into(), formulas: vec![] }], &ctx())
            .await
            .unwrap();
        assert_eq!(out[0].text, "好");
    }

    #[tokio::test]
    async fn llm_401_fails_fast_without_retry() {
        let (base, mut rx) = mock_server(vec![("401 Unauthorized", r#"{"error":"bad key"}"#.into())])
            .await;
        let provider = Provider::Llm {
            base_url: format!("{base}/v1"),
            api_key: "k".into(),
            model: "m".into(),
        };
        let err = provider
            .translate_segments(&[Segment { text: "x".into(), formulas: vec![] }], &ctx())
            .await
            .unwrap_err();
        assert!(err.to_string().contains("401"), "{err}");
        // Exactly one request was served (no retry on 4xx).
        assert!(rx.recv().await.is_some());
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn deepl_batch_aligns_and_restores_tags() {
        let (base, mut rx) = mock_server(vec![(
            "200 OK",
            r#"{"translations":[{"text":"当 <m0>x2 +y</m0> 很大"},{"text":"第二段"}]}"#.into(),
        )])
        .await;
        let provider = Provider::DeepL {
            base_url: base.clone(),
            api_key: "k".into(),
        };
        let segments = vec![
            Segment { text: "when x2 +y is big".into(), formulas: vec![formula(0, "x2 +y")] },
            Segment { text: "second".into(), formulas: vec![] },
        ];
        let out = provider.translate_segments(&segments, &ctx()).await.unwrap();
        assert_eq!(out.len(), 2);
        // The <m0> pair came back as the token, exactly once -> ok.
        assert!(out[0].text.contains("MATH_0"), "{}", out[0].text);
        assert!(!out[0].text.contains("<m0>"), "{}", out[0].text);
        assert_eq!(out[0].formula_ok, vec![true]);
        assert_eq!(out[1].text, "第二段");

        let req = rx.recv().await.unwrap();
        assert!(req.contains("POST /v2/translate"), "{req}");
        assert!(req.contains("DeepL-Auth-Key k"), "{req}");
        assert!(req.contains("\"tag_handling\":\"xml\""), "{req}");
        assert!(req.contains("\"ignore_tags\":[\"m0\"]"), "{req}");
    }

    #[tokio::test]
    async fn deepl_count_mismatch_is_an_error() {
        let (base, _rx) = mock_server(vec![(
            "200 OK",
            r#"{"translations":[{"text":"only one"}]}"#.into(),
        )])
        .await;
        let provider = Provider::DeepL {
            base_url: base,
            api_key: "k".into(),
        };
        let segments = vec![
            Segment { text: "a".into(), formulas: vec![] },
            Segment { text: "b".into(), formulas: vec![] },
        ];
        let err = provider.translate_segments(&segments, &ctx()).await.unwrap_err();
        assert!(err.to_string().contains("数量不匹配"), "{err}");
    }
}
