//! Export formatters for annotations (FEATURES 4.5.2 / 4.5.3, M3; 5.6 image
//! marks merged in M5).
//!
//! Pure functions over annotation lists -- no DB or FFI access, so the exact
//! output formats are unit-testable. The api layer feeds these the rows from
//! the repositories and returns the string to Flutter, which writes it to a
//! user-chosen file.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use crate::models::annotation::{
    ImageAnnotation, ImageAnnotationKind, TextAnnotation, TextAnnotationKind,
};

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

/// Extract a string field from a JSON payload (marks store kind-specific
/// data as opaque JSON; the export only reads human-readable bits).
fn payload_field(payload: &str, key: &str) -> Option<String> {
    serde_json::from_str::<Value>(payload)
        .ok()
        .and_then(|v| v.get(key)?.as_str().map(String::from))
}

/// Render one Markdown bullet for an image-layer mark (FEATURES 5.6): sticky
/// notes quote their text, stamps name their image, brush/shape summarize
/// their geometry.
fn image_mark_line(mark: &ImageAnnotation) -> String {
    let (icon, label) = match mark.kind {
        ImageAnnotationKind::Brush => ("🖌", "画笔"),
        ImageAnnotationKind::Shape => ("⬜", "形状"),
        ImageAnnotationKind::Sticky => ("📌", "便签"),
        ImageAnnotationKind::Stamp => ("🔖", "图章"),
    };
    let detail = match mark.kind {
        ImageAnnotationKind::Sticky => {
            payload_field(&mark.payload, "text").unwrap_or_default()
        }
        ImageAnnotationKind::Stamp => {
            payload_field(&mark.payload, "file").unwrap_or_default()
        }
        ImageAnnotationKind::Shape => {
            payload_field(&mark.payload, "shapeType")
                .map(|t| format!("（{t}）"))
                .unwrap_or_default()
        }
        ImageAnnotationKind::Brush => format!(
            "（{} 个点）",
            serde_json::from_str::<Value>(&mark.payload)
                .ok()
                .and_then(|v| v.get("points")?.as_array().map(|a| a.len()))
                .unwrap_or(0)
        ),
    };
    let mut line = format!("- {icon} {label}{detail}\n");
    if mark.kind == ImageAnnotationKind::Sticky {
        if let Some(text) = payload_field(&mark.payload, "text") {
            if !text.is_empty() {
                line.push_str(&format!("  > {}\n", text.replace('\n', "\n  > ")));
            }
        }
    }
    line
}

/// Render the Markdown export: `# 阅读标注`, grouped by page as
/// `## 第 N 页`, one bullet per annotation (text-layer marks first, then
/// image-layer marks, both arriving sorted by page). Notes append their
/// content as an indented quote. A book without annotations yields a
/// placeholder note (FEATURES 4.5.2 / 5.6).
pub fn annotations_markdown(
    annotations: &[TextAnnotation],
    image_marks: &[ImageAnnotation],
) -> String {
    let mut out = String::from("# 阅读标注\n");
    if annotations.is_empty() && image_marks.is_empty() {
        out.push_str("\n> 暂无标注\n");
        return out;
    }

    // Group both kinds by page (BTreeMap keeps ascending page order).
    let mut pages: BTreeMap<i64, Vec<String>> = BTreeMap::new();
    for ann in annotations {
        let text = ann.text.as_deref().unwrap_or("");
        let mut line = format!("- {} {}：{}\n", kind_icon(ann.kind), kind_label(ann.kind), text);
        if let Some(content) = ann.content.as_deref() {
            if !content.is_empty() {
                line.push_str(&format!("  > {}\n", content.replace('\n', "\n  > ")));
            }
        }
        pages.entry(ann.page).or_default().push(line);
    }
    for mark in image_marks {
        pages.entry(mark.page).or_default().push(image_mark_line(mark));
    }

    for (page, lines) in pages {
        out.push_str(&format!("\n## 第 {} 页\n\n", page + 1));
        for line in lines {
            out.push_str(&line);
        }
    }
    out
}

/// Wrapper object for the JSON export: book id + full annotation rows
/// (coords + style, FEATURES 4.5.3) + image-layer marks (5.6).
#[derive(Serialize)]
struct AnnotationExport<'a> {
    book_id: i64,
    annotations: &'a [TextAnnotation],
    image_marks: &'a [ImageAnnotation],
}

/// Render the pretty-printed JSON export (FEATURES 4.5.3 / 5.6).
pub fn annotations_json(
    book_id: i64,
    annotations: &[TextAnnotation],
    image_marks: &[ImageAnnotation],
) -> String {
    serde_json::to_string_pretty(&AnnotationExport {
        book_id,
        annotations,
        image_marks,
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

    fn mark(
        id: i64,
        page: i64,
        kind: ImageAnnotationKind,
        payload: &str,
    ) -> ImageAnnotation {
        ImageAnnotation {
            id,
            book_id: 1,
            page,
            kind,
            x: 0.5,
            y: 0.5,
            w: None,
            h: None,
            rotation: 0.0,
            payload: payload.into(),
            style: "{}".into(),
            created_at: "2026-08-06 10:00:00".into(),
        }
    }

    #[test]
    fn markdown_empty_has_placeholder() {
        let md = annotations_markdown(&[], &[]);
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
        let md = annotations_markdown(&anns, &[]);
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
        let md = annotations_markdown(&[ann(1, 0, TextAnnotationKind::Note, Some("t"), None)], &[]);
        assert!(md.contains("- 📝 笔记：t\n"));
        assert!(!md.contains(">"));
    }

    #[test]
    fn markdown_merges_image_marks_by_page() {
        let anns = vec![ann(1, 0, TextAnnotationKind::Highlight, Some("sel"), None)];
        let marks = vec![
            mark(10, 0, ImageAnnotationKind::Sticky, r#"{"text":"贴在页上的便签"}"#),
            mark(11, 1, ImageAnnotationKind::Stamp, r#"{"file":"stamps/a.png"}"#),
            mark(12, 1, ImageAnnotationKind::Brush, r#"{"points":[[0,0],[1,1]]}"#),
            mark(13, 1, ImageAnnotationKind::Shape, r#"{"shapeType":"arrow"}"#),
        ];
        let md = annotations_markdown(&anns, &marks);
        assert!(md.contains("## 第 1 页"));
        assert!(md.contains("- 📌 便签贴在页上的便签"));
        assert!(md.contains("  > 贴在页上的便签"));
        assert!(md.contains("## 第 2 页"));
        assert!(md.contains("- 🔖 图章stamps/a.png"));
        assert!(md.contains("- 🖌 画笔（2 个点）"));
        assert!(md.contains("- ⬜ 形状（arrow）"));
    }

    #[test]
    fn json_is_pretty_and_contains_coords() {
        let anns = vec![ann(1, 0, TextAnnotationKind::Highlight, Some("sel"), None)];
        let marks = vec![mark(2, 0, ImageAnnotationKind::Stamp, r#"{"file":"s.png"}"#)];
        let json = annotations_json(7, &anns, &marks);
        assert!(json.contains("\"book_id\": 7"));
        assert!(json.contains("\"kind\": \"highlight\""));
        assert!(json.contains("\"text\": \"sel\""));
        assert!(json.contains("\"rects\""));
        assert!(json.contains("\"x\": 0.1"));
        assert!(json.contains("\"color\": \"#ff0000\""));
        assert!(json.contains("\"image_marks\""));
        assert!(json.contains("\"kind\": \"stamp\""));
        assert!(json.contains('\n')); // pretty-printed
    }
}
