//! System prompts for AI actions (FEATURES 6.2).
//!
//! Pure functions -- unit-testable, and the single place the action
//! specifications (6.2.1/6.2.2/6.2.3/6.6.2) are encoded as text.

/// Translate system prompt (FEATURES 6.2.1): translate into the target
/// language, keep technical terms with the original in parentheses.
pub fn translate_system(target_lang: &str) -> String {
    format!(
        "你是一名专业翻译。请将用户提供的文本翻译为{target_lang}。\
         专业术语在翻译后用括号标注原文。中英互译时保持译文自然流畅。\
         只输出译文，不要添加任何解释或注释。"
    )
}

/// Explain system prompt (FEATURES 6.2.2): answer concisely first, then ask
/// whether the user wants a detailed expansion (background / term usage /
/// code analysis).
pub fn explain_system() -> String {
    "你是一名学识渊博的讲解者。请对用户提供的文本先给出简洁明了的解释\
     （1-2 句，直击要点），然后询问用户是否需要详细展开（如背景知识、\
     术语详解、代码功能分析等）。使用 Markdown 格式输出。"
        .to_string()
}

/// Search system prompt (FEATURES 6.2.3). With web search enabled the model
/// is asked for a concise summary + follow-up question; without it, it
/// answers from knowledge, says so explicitly, and offers to expand (no
/// external search service is integrated -- M4 scope: prompt-level).
pub fn search_system(web_search_enabled: bool) -> String {
    if web_search_enabled {
        "你正在执行联网搜索。请先给出简洁的搜索摘要（3-5 条要点，每条一句话），\
         并在结尾询问用户是否需要针对某一点详细展开；若无法确认来源，请明确说明。"
            .to_string()
    } else {
        "你正在回答用户的问题。当前未启用联网搜索，请基于已有知识先给出简洁的要点，\
         并在开头注明“未启用联网搜索，以下为基于已有知识的回答”，\
         结尾询问用户是否需要详细展开。"
            .to_string()
    }
}

/// Search system prompt when real web search results are available: answer
/// strictly from the provided results, citing their links (no fabrication).
pub fn search_system_with_results(results: &str) -> String {
    format!(
        "你正在执行联网搜索。以下是搜索到的真实结果，请基于这些结果给出简洁的\
         摘要（3-5 条要点），每条要点附上对应的来源链接，并在结尾询问用户\
         是否需要详细展开。只能引用下方结果中的链接，不得编造来源。\n\n\
         搜索到的结果：\n{results}"
    )
}

/// Search system prompt when web search is enabled but no API key is
/// configured: fall back to knowledge and say so.
pub fn search_no_key_system() -> String {
    "你正在回答用户的问题。联网搜索功能已开启但未配置搜索 API Key，\
     请基于已有知识先给出简洁的要点，并在开头注明“未配置联网搜索，\
     以下为基于已有知识的回答”，结尾询问用户是否需要详细展开。"
        .to_string()
}

/// Search system prompt when the web search request itself failed: answer
/// from knowledge, but state the failure up front (no silent fallback).
pub fn search_failed_system(reason: &str) -> String {
    format!(
        "你正在回答用户的问题。联网搜索请求失败（{reason}），\
         请基于已有知识先给出简洁的要点，并在开头注明“联网搜索失败，\
         以下为基于已有知识的回答”，结尾询问用户是否需要详细展开。"
    )
}

/// Generic chat system prompt (FEATURES 6.2.4): concise answers, offer to
/// expand when the topic is deep.
pub fn chat_system() -> String {
    "你是一个乐于助人的 AI 助手，请使用 Markdown 格式回答。回答保持简洁明了；\
     内容较多时先给出要点，并询问用户是否需要详细展开。"
        .to_string()
}

/// Vision prompt (FEATURES 6.6.2 / 7.2, 区域识图): recognize and analyze the
/// screenshot the user captured; extract any text verbatim, describe charts /
/// figures, and answer in Markdown.
pub fn vision_prompt() -> String {
    "请识别并分析这张图片的内容。如果包含文字，请完整、准确地识别出来；\
     如果是图表或插图，请描述其内容与要点。使用 Markdown 格式回答。"
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn translate_prompt_mentions_target_lang_and_terms() {
        let p = translate_system("中文");
        assert!(p.contains("中文"));
        assert!(p.contains("专业术语"));
        assert!(p.contains("括号标注原文"));
    }

    #[test]
    fn explain_prompt_is_concise_then_offers_expansion() {
        let p = explain_system();
        assert!(p.contains("简洁明了"));
        assert!(p.contains("询问"));
        assert!(p.contains("详细展开"));
        assert!(p.contains("术语"));
    }

    #[test]
    fn search_prompt_differs_by_web_toggle() {
        let on = search_system(true);
        let off = search_system(false);
        assert!(on.contains("简洁"));
        assert!(on.contains("询问"));
        assert!(on.contains("详细展开"));
        assert!(!on.contains("未启用联网搜索"));
        assert!(off.contains("未启用联网搜索"));
        assert!(off.contains("已有知识"));
        assert!(off.contains("询问"));
    }

    #[test]
    fn search_with_results_embeds_results_and_bans_fabrication() {
        let p = search_system_with_results("1. Rust 官网\n  链接: https://www.rust-lang.org/");
        assert!(p.contains("https://www.rust-lang.org/"));
        assert!(p.contains("不得编造来源"));
        assert!(p.contains("来源链接"));
        assert!(p.contains("询问"));
    }

    #[test]
    fn search_no_key_notes_missing_key_and_uses_knowledge() {
        let p = search_no_key_system();
        assert!(p.contains("未配置联网搜索"));
        assert!(p.contains("已有知识"));
        assert!(p.contains("询问"));
        assert!(!p.contains("搜索到的结果"));
    }

    #[test]
    fn search_failed_notes_reason_and_uses_knowledge() {
        let p = search_failed_system("HTTP 401");
        assert!(p.contains("HTTP 401"));
        assert!(p.contains("联网搜索失败"));
        assert!(p.contains("已有知识"));
        assert!(p.contains("询问"));
    }

    #[test]
    fn chat_prompt_is_concise_and_offers_expansion() {
        let p = chat_system();
        assert!(p.contains("简洁明了"));
        assert!(p.contains("询问"));
        assert!(p.contains("详细展开"));
    }

    #[test]
    fn vision_prompt_asks_to_recognize_text_and_describe_figures() {
        let p = vision_prompt();
        assert!(p.contains("识别"));
        assert!(p.contains("图片"));
        assert!(p.contains("文字"));
        assert!(p.contains("Markdown"));
    }

}
