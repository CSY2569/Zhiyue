//! Merge user edits over a document's original outline.
//!
//! pdfium exposes an outline for READING only -- there is no write API -- so
//! edits (rename / hide / reorder / added bookmarks) live in the
//! `book_outline_overrides` table and are applied here at read time. The PDF
//! file itself is never rewritten.
//!
//! Everything in this module is a pure function over plain data so it can be
//! tested without a database or a pdfium document.

use crate::pdf::types::OutlineEntry;

/// One stored edit, addressed by the key the merge assigns to a node.
#[derive(Debug, Clone, PartialEq)]
pub struct OutlineOverride {
    pub entry_key: String,
    pub parent_key: Option<String>,
    pub title: Option<String>,
    pub page: Option<i64>,
    pub order_index: Option<i64>,
    pub hidden: bool,
}

/// Key of the [index]-th top-level node.
pub fn top_key(index: usize) -> String {
    format!("pdf:{index}")
}

/// Key of a nested node: parent key + the child's index.
pub fn child_key(parent: &str, index: usize) -> String {
    format!("{parent}.{index}")
}

/// Prefix used for bookmarks the user created (no counterpart in the file).
pub const BOOKMARK_PREFIX: &str = "bm:";

fn index_of(overrides: &[OutlineOverride]) -> std::collections::HashMap<&str, &OutlineOverride> {
    overrides.iter().map(|o| (o.entry_key.as_str(), o)).collect()
}

fn sort_key(order_index: Option<i64>, position: usize) -> (i64, usize) {
    (order_index.unwrap_or(i64::MAX), position)
}

/// Merge [overrides] over [base].
///
/// - `title` replaces the node's text (when present).
/// - `hidden` drops the node AND its subtree.
/// - `order_index` re-sorts among siblings; nodes without one keep the
///   document's relative order after the explicitly ordered ones.
/// - overrides whose key starts with [`BOOKMARK_PREFIX`] are nodes the user
///   created; they are inserted at their `parent_key` level (top level when
///   `parent_key` is `None`).
///
/// Keys address nodes by their ORIGINAL document position, so hiding a node
/// never shifts another node's key. Overrides that reference a node which no
/// longer exists are ignored rather than resurrecting stale entries -- the
/// file may have been replaced by a different edition. A bookmark whose
/// parent disappeared is promoted to the top level instead of being dropped:
/// losing the user's own bookmark would be worse than a flat tree.
pub fn merge(base: Vec<OutlineEntry>, overrides: &[OutlineOverride]) -> Vec<OutlineEntry> {
    let by_key = index_of(overrides);
    let mut at_level: std::collections::HashMap<String, Vec<&OutlineOverride>> =
        std::collections::HashMap::new();
    let mut top: Vec<&OutlineOverride> = Vec::new();
    for o in overrides.iter().filter(|o| o.entry_key.starts_with(BOOKMARK_PREFIX)) {
        match &o.parent_key {
            None => top.push(o),
            Some(p) => at_level.entry(p.clone()).or_default().push(o),
        }
    }
    let mut used: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut merged = build_level(base, None, &top, &at_level, &by_key, &mut used);
    // Bookmarks whose parent was hidden or is gone.
    for (key, list) in at_level.iter() {
        if !used.contains(key) {
            for o in list {
                merged.push(bookmark_node(o));
            }
        }
    }
    merged
}

fn bookmark_node(o: &OutlineOverride) -> OutlineEntry {
    OutlineEntry {
        title: o.title.clone().unwrap_or_else(|| "书签".to_string()),
        page: o.page.unwrap_or(-1),
        children: Vec::new(),
    }
}

fn build_level(
    nodes: Vec<OutlineEntry>,
    parent: Option<&str>,
    extra: &[&OutlineOverride],
    at_level: &std::collections::HashMap<String, Vec<&OutlineOverride>>,
    by_key: &std::collections::HashMap<&str, &OutlineOverride>,
    used: &mut std::collections::HashSet<String>,
) -> Vec<OutlineEntry> {
    // (sort key, position, node) -- position keeps document order stable for
    // nodes without an explicit order_index, and pushes added bookmarks after
    // them.
    let mut items: Vec<(i64, usize, OutlineEntry)> = Vec::new();
    for (i, node) in nodes.into_iter().enumerate() {
        let key = match parent {
            None => top_key(i),
            Some(p) => child_key(p, i),
        };
        let ov = by_key.get(key.as_str()).copied();
        if ov.map(|o| o.hidden).unwrap_or(false) {
            continue;
        }
        let children_extra = at_level.get(&key).map(|v| v.as_slice()).unwrap_or(&[]);
        if !children_extra.is_empty() || at_level.contains_key(&key) {
            used.insert(key.clone());
        }
        let title = ov
            .and_then(|o| o.title.clone())
            .unwrap_or(node.title);
        let page = ov.and_then(|o| o.page).unwrap_or(node.page);
        let children = build_level(
            node.children,
            Some(&key),
            children_extra,
            at_level,
            by_key,
            used,
        );
        let order = ov.and_then(|o| o.order_index).unwrap_or(i64::MAX);
        items.push((
            order,
            items.len(),
            OutlineEntry {
                title,
                page,
                children,
            },
        ));
    }
    let base_pos = items.len();
    for (j, o) in extra.iter().enumerate() {
        items.push((
            o.order_index.unwrap_or(i64::MAX),
            base_pos + j,
            bookmark_node(o),
        ));
    }
    items.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
    items.into_iter().map(|(_, _, node)| node).collect()
}
#[cfg(test)]
mod tests {
    use super::*;

    fn entry(title: &str, page: i64, children: Vec<OutlineEntry>) -> OutlineEntry {
        OutlineEntry {
            title: title.into(),
            page,
            children,
        }
    }

    fn ov(key: &str) -> OutlineOverride {
        OutlineOverride {
            entry_key: key.into(),
            parent_key: None,
            title: None,
            page: None,
            order_index: None,
            hidden: false,
        }
    }

    fn base() -> Vec<OutlineEntry> {
        vec![
            entry(
                "第一章",
                0,
                vec![entry("1.1 小节", 1, vec![]), entry("1.2 小节", 2, vec![])],
            ),
            entry("第二章", 3, vec![]),
        ]
    }

    fn titles(nodes: &[OutlineEntry]) -> Vec<&str> {
        nodes.iter().map(|n| n.title.as_str()).collect()
    }

    #[test]
    fn without_overrides_the_tree_is_unchanged() {
        let merged = merge(base(), &[]);
        assert_eq!(titles(&merged), ["第一章", "第二章"]);
        assert_eq!(titles(&merged[0].children), ["1.1 小节", "1.2 小节"]);
        assert_eq!(merged[0].page, 0);
    }

    #[test]
    fn rename_replaces_only_the_touched_node() {
        let mut o = ov("pdf:0");
        o.title = Some("楔子".into());
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged), ["楔子", "第二章"]);
        assert_eq!(titles(&merged[0].children), ["1.1 小节", "1.2 小节"]);
    }

    #[test]
    fn hiding_a_node_drops_its_subtree_too() {
        let mut o = ov("pdf:0");
        o.hidden = true;
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged), ["第二章"]);
    }

    #[test]
    fn order_index_sorts_siblings_and_leaves_the_rest_in_document_order() {
        // Pull 第二章 (index 1) to the front; 第一章 keeps the implicit tail.
        let mut o = ov("pdf:1");
        o.order_index = Some(-1);
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged), ["第二章", "第一章"]);
    }

    #[test]
    fn page_override_retargets_a_node() {
        let mut o = ov("pdf:1");
        o.page = Some(9);
        let merged = merge(base(), &[o]);
        assert_eq!(merged[1].page, 9);
    }

    #[test]
    fn a_user_bookmark_lands_at_top_level() {
        let mut o = ov("bm:1");
        o.title = Some("我的书签".into());
        o.page = Some(7);
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged), ["第一章", "第二章", "我的书签"]);
        assert_eq!(merged[2].page, 7);
    }

    #[test]
    fn a_user_bookmark_can_hang_under_a_document_node() {
        let mut o = ov("bm:deep");
        o.parent_key = Some("pdf:0".into());
        o.title = Some("重点".into());
        o.page = Some(1);
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged[0].children), ["1.1 小节", "1.2 小节", "重点"]);
    }

    #[test]
    fn a_bookmark_whose_parent_vanished_stays_reachable() {
        let mut parent_hidden = ov("pdf:0");
        parent_hidden.hidden = true;
        let mut child = ov("bm:orphan");
        child.parent_key = Some("pdf:0".into());
        child.title = Some("孤儿书签".into());
        child.page = Some(4);
        let merged = merge(base(), &[parent_hidden, child]);
        // Losing the bookmark would be worse than showing it at the top.
        assert_eq!(titles(&merged), ["第二章", "孤儿书签"]);
    }

    #[test]
    fn stale_overrides_are_ignored() {
        let mut o = ov("pdf:9.9");
        o.title = Some("不复存在".into());
        let merged = merge(base(), &[o]);
        assert_eq!(titles(&merged), ["第一章", "第二章"]);
    }
}
