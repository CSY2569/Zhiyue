//! Export formatters for annotations (FEATURES 4.5.2 / 4.5.3, M3).
//!
//! Pure functions over a list of [`TextAnnotation`] -- no DB or FFI access, so
//! the exact output formats are unit-testable. The api layer feeds these the
//! rows from `annotation_repo::list` and returns the string to Flutter, which
//! writes it to a user-chosen file.

use serde::Serialize;

use crate::models::annotation::{TextAnnotation, TextAnnotationKind};

/// Kind icon used in the Markdown export (FEATURES 4.5.2).
fn kind_icon(kind: TextAnnotationKind) -> &'static str {
    match kind {
        TextAnnotationKind::Highlight => "🔆",
        TextAnnotationKind::Underline => "➖",
        TextAnnotationKind::Strikethrough => "🚫",
        TextAnnotationKind::Note => "📝",
    }
}

/// Kind label used in the Markdown export.
fn kind_label(kind: TextAnnotationKind) -> &'static str {
    match kind {
        TextAnnotationKind::Highlight => "高亮",
        TextAnnotationKind::Underline => "下划线",
        TextAnnotationKind::Strikethrough => "删除线",
        TextAnnotationKind::Note => "笔记",
    }
}

/// Render the Markdown export: `# 阅读标注`, grouped by page as
/// `## 第 N 页`, one bullet per annotation. Notes append their content as an
/// indented quote. A book without annotations yields a placeholder note
/// (FEATURES 4.5.2).
pub fn annotations_markdown(annotations: &[TextAnnotation]) -> String {
    let mut out = String::from("# 阅读标注\n");
    if annotations.is_empty() {
        out.push_str("\n> 暂无标注\n");
        return out;
    }

    // Group consecutive rows by page (repo already sorts by page).
    let mut current_page: Option<i64> = None;
    for ann in annotations {
        if current_page != Some(ann.page) {
            current_page = Some(ann.page);
            out.push_str(&format!("\n## 第 {} 页\n\n", ann.page + 1));
        }
        let text = ann.text.as_deref().unwrap_or("");
        out.push_str(&format!("- {} {}：{}\n", kind_icon(ann.kind), kind_label(ann.kind), text));
        if let Some(content) = ann.content.as_deref() {
            if !content.is_empty() {
                out.push_str(&format!("  > {}\n", content.replace('\n', "\n  > ")));
            }
        }
    }
    out
}

/// Wrapper object for the JSON export: book id + full annotation rows
/// (coords + style, FEATURES 4.5.3).
#[derive(Serialize)]
struct AnnotationExport<'a> {
    book_id: i64,
    annotations: &'a [TextAnnotation],
}

/// Render the pretty-printed JSON export (FEATURES 4.5.3).
pub fn annotations_json(book_id: i64, annotations: &[TextAnnotation]) -> String {
    serde_json::to_string_pretty(&AnnotationExport {
        book_id,
        annotations,
    })
    .unwrap_or_else(|_| "{\"error\":\"serialization failed\"}".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::annotation::NormRect;

    fn ann(
        id: i64,
        page: i64,
        kind: TextAnnotationKind,
        text: Option<&str>,
        content: Option<&str>,
    ) -> TextAnnotation {
        TextAnnotation {
            id,
            book_id: 1,
            page,
            kind,
            text: text.map(String::from),
            content: content.map(String::from),
            rects: vec![NormRect {
                x: 0.1,
                y: 0.2,
                w: 0.3,
                h: 0.04,
            }],
            color: Some("#ff0000".into()),
            created_at: "2026-08-06 10:00:00".into(),
            updated_at: "2026-08-06 10:00:00".into(),
        }
    }

    #[test]
    fn markdown_empty_has_placeholder() {
        let md = annotations_markdown(&[]);
        assert!(md.starts_with("# 阅读标注"));
        assert!(md.contains("暂无标注"));
    }

    #[test]
    fn markdown_groups_by_page_with_icons() {
        let anns = vec![
            ann(1, 0, TextAnnotationKind::Highlight, Some("first line"), None),
            ann(2, 0, TextAnnotationKind::Underline, Some("second line"), None),
            ann(3, 2, TextAnnotationKind::Note, Some("third line"), Some("my note\nwith two lines")),
            ann(4, 2, TextAnnotationKind::Strikethrough, Some("fourth line"), None),
        ];
        let md = annotations_markdown(&anns);
        assert!(md.contains("## 第 1 页"));
        assert!(md.contains("## 第 3 页"));
        assert!(md.contains("- 🔆 高亮：first line"));
        assert!(md.contains("- ➖ 下划线：second line"));
        assert!(md.contains("- 📝 笔记：third line"));
        assert!(md.contains("  > my note\n  > with two lines"));
        assert!(md.contains("- 🚫 删除线：fourth line"));
        // Page 2 (index 1) has no annotations and must not appear.
        assert!(!md.contains("## 第 2 页"));
    }

    #[test]
    fn markdown_note_without_content_has_no_quote() {
        let md = annotations_markdown(&[ann(1, 0, TextAnnotationKind::Note, Some("t"), None)]);
        assert!(md.contains("- 📝 笔记：t\n"));
        assert!(!md.contains(">"));
    }

    #[test]
    fn json_is_pretty_and_contains_coords() {
        let anns = vec![ann(1, 0, TextAnnotationKind::Highlight, Some("sel"), None)];
        let json = annotations_json(7, &anns);
        assert!(json.contains("\"book_id\": 7"));
        assert!(json.contains("\"kind\": \"highlight\""));
        assert!(json.contains("\"text\": \"sel\""));
        assert!(json.contains("\"rects\""));
        assert!(json.contains("\"x\": 0.1"));
        assert!(json.contains("\"color\": \"#ff0000\""));
        assert!(json.contains('\n')); // pretty-printed
    }
}
