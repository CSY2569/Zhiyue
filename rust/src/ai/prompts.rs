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

/// The built-in role templates (AI reply settings): each is a *role
/// segment* prepended to the per-action system prompt, so translation /
/// explanation / search keep their action instructions (settings 设置 →
/// AI 回复). "general" adds nothing.
pub fn template_prompt(template_id: &str, custom: &str) -> String {
    match template_id {
        "academic" => "你是一位严谨的学术阅读助手。面对论文、专著与学术材料时，\
            侧重论证逻辑、研究方法和术语准确性；引用时区分原文观点与你的解读。"
            .to_string(),
        "novel" => "你是一位细腻的文学阅读伴侣。面对小说与文学作品时，\
            关注人物、情节、主题与写作手法，回答带有文学品味且不过度剧透。"
            .to_string(),
        "tech" => "你是一位资深技术文档顾问。面对技术文档、手册与代码时，\
            回答准确、结构化，优先给出可操作的结论，并指出关键注意事项。"
            .to_string(),
        "language" => "你是一位耐心的外语学习导师。面对外文材料时，\
            除了内容本身，主动解释疑难句式和生词，并给出中文对照帮助理解。"
            .to_string(),
        "historical" => "你是一位博学的历史文献研究者。面对史料、古籍与历史著作时，\
            注重史实考据、时代背景与史料来源辨析，区分客观史实与后世评述；\
            涉及争议观点时说明不同学派的看法。"
            .to_string(),
        "legal" => "你是一位严谨的法律文书专家。面对法律条文、合同与判决书等材料时，\
            注重法条原文、条款结构与法律术语的精确含义；分析时区分事实认定与法律适用，\
            并提示潜在风险（不构成正式法律意见）。"
            .to_string(),
        "classical" => "你是一位精通古文的国学顾问。面对文言文时，\
            先给出准确的白话翻译，再逐句解释关键实词、虚词与句式\
            （如倒装、省略、词类活用），最后点明出处与时代背景。"
            .to_string(),
        "ai" => "你是一位前沿 AI 技术专家。面对人工智能相关的文献与代码时，\
            解释模型原理、算法与工程实现，关注技术可行性、局限性与最佳实践，\
            保持术语准确。"
            .to_string(),
        "custom" => {
            let custom = custom.trim();
            if custom.is_empty() {
                String::new()
            } else {
                custom.to_string()
            }
        }
        _ => String::new(), // "general" and unknown ids
    }
}

/// Compose the full system prompt: role template (if any) + the action
/// instructions, joined by a blank line.
pub fn system_prompt(template_id: &str, custom: &str, action_prompt: &str) -> String {
    let role = template_prompt(template_id, custom);
    if role.is_empty() {
        action_prompt.to_string()
    } else {
        format!("{role}\n\n{action_prompt}")
    }
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


    #[test]
    fn system_prompt_prepends_role_template_to_action_instructions() {
        // Built-in template: role segment first, action instructions after.
        let p = system_prompt("academic", "", "动作指令");
        assert!(p.contains("学术阅读助手"), "{p}");
        assert!(p.contains("动作指令"));
        assert!(p.find("学术").unwrap() < p.find("动作指令").unwrap());

        // "general" and unknown ids add nothing.
        assert_eq!(system_prompt("general", "", "动作指令"), "动作指令");
        assert_eq!(system_prompt("unknown", "", "动作指令"), "动作指令");

        // The extra templates each carry a fitting role segment.
        assert!(system_prompt("historical", "", "指令").contains("历史文献"));
        assert!(system_prompt("legal", "", "指令").contains("法律"));
        assert!(system_prompt("classical", "", "指令").contains("文言文"));
        assert!(system_prompt("ai", "", "指令").contains("AI 技术"));

        // Custom: the user's text becomes the role segment; empty custom
        // text degrades to the bare action instructions.
        let c = system_prompt("custom", "你是一位诗人", "动作指令");
        assert!(c.starts_with("你是一位诗人"), "{c}");
        assert!(c.contains("动作指令"));
        assert_eq!(system_prompt("custom", "   ", "动作指令"), "动作指令");
    }
}
