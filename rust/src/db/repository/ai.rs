//! `ai_threads` / `ai_messages` repository (FEATURES 9.1.7 / 6.5.4).
//!
//! Persisted multi-turn conversation windows: one window per book (book_id),
//! plus their messages, so the AI side panel survives app restarts. Messages
//! cascade-delete with their window (FK).

use rusqlite::{params, Connection, Row};

use crate::error::AppResult;
use crate::models::ai::{AiActionType, AiMessage, AiRole, AiThread};

/// Columns selected from `ai_threads`, in the order `row_to_thread` expects.
const THREAD_COLS: &str = "id, title, action_type, book_id, created_at, updated_at";

/// Columns selected from `ai_messages`, in the order `row_to_message` expects.
/// `action_type` was added in schema v6 (NULL on legacy rows).
const MESSAGE_COLS: &str = "id, thread_id, role, content, image_path, action_type, created_at";

fn row_to_thread(row: &Row) -> rusqlite::Result<AiThread> {
    let action: String = row.get(2)?;
    Ok(AiThread {
        id: row.get(0)?,
        title: row.get(1)?,
        action_type: AiActionType::from_db_str(&action).unwrap_or(AiActionType::Chat),
        book_id: row.get(3)?,
        created_at: row.get(4)?,
        updated_at: row.get(5)?,
    })
}

fn row_to_message(row: &Row) -> rusqlite::Result<AiMessage> {
    let role: String = row.get(2)?;
    let action: Option<String> = row.get(5)?;
    Ok(AiMessage {
        id: row.get(0)?,
        thread_id: row.get(1)?,
        role: AiRole::from_db_str(&role).unwrap_or(AiRole::User),
        content: row.get(3)?,
        image_path: row.get(4)?,
        action_type: action.as_deref().and_then(AiActionType::from_db_str),
        created_at: row.get(6)?,
    })
}

/// List all threads, most recently updated first (FEATURES 6.5.3 history
/// list; `id DESC` breaks same-second ties deterministically).
pub fn list_threads(conn: &Connection) -> AppResult<Vec<AiThread>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {THREAD_COLS} FROM ai_threads ORDER BY updated_at DESC, id DESC"
    ))?;
    let rows = stmt.query_map([], row_to_thread)?;
    let mut threads = Vec::new();
    for row in rows {
        threads.push(row?);
    }
    Ok(threads)
}

/// List a thread's messages in conversation order.
pub fn list_messages(conn: &Connection, thread_id: i64) -> AppResult<Vec<AiMessage>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT {MESSAGE_COLS} FROM ai_messages \
         WHERE thread_id = ?1 ORDER BY created_at, id"
    ))?;
    let rows = stmt.query_map(params![thread_id], row_to_message)?;
    let mut messages = Vec::new();
    for row in rows {
        messages.push(row?);
    }
    Ok(messages)
}

/// Insert a new conversation window; returns the new row id. `book_id` is
/// the owning book (null = the no-book window); a unique partial index
/// enforces one window per book.
pub fn create_thread(
    conn: &Connection,
    title: &str,
    action_type: AiActionType,
    book_id: Option<i64>,
) -> AppResult<i64> {
    conn.execute(
        "INSERT INTO ai_threads (title, action_type, book_id) VALUES (?1, ?2, ?3)",
        params![title, action_type.as_str(), book_id],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Append a message, bump the window's `updated_at`, and refresh its
/// `action_type` (the history-list icon shows the latest action) in one
/// transaction. The per-message `action_type` (v6) is also written so the
/// history view can label each turn with its originating instruction.
pub fn append_message(
    conn: &Connection,
    thread_id: i64,
    role: AiRole,
    content: &str,
    image_path: Option<&str>,
    action_type: Option<AiActionType>,
) -> AppResult<()> {
    let tx = conn.unchecked_transaction()?;
    tx.execute(
        "INSERT INTO ai_messages (thread_id, role, content, image_path, action_type) \
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            thread_id,
            role.as_str(),
            content,
            image_path,
            action_type.map(|a| a.as_str()),
        ],
    )?;
    tx.execute(
        "UPDATE ai_threads SET updated_at = datetime('now'), \
         action_type = COALESCE(?2, action_type) WHERE id = ?1",
        params![thread_id, action_type.map(|a| a.as_str())],
    )?;
    tx.commit()?;
    Ok(())
}

/// Delete one conversation window (its messages go with it via cascade).
/// Returns whether a row was actually removed.
pub fn delete_thread(conn: &Connection, thread_id: i64) -> AppResult<bool> {
    let n = conn.execute("DELETE FROM ai_threads WHERE id = ?1", params![thread_id])?;
    Ok(n > 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::schema::{ensure_ai_window_indexes, PRAGMAS, SCHEMA_SQL};
    use rusqlite::Connection;

    /// In-memory DB with the real schema (v3: book_id + window indexes).
    fn test_conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        for pragma in PRAGMAS {
            conn.execute_batch(pragma).unwrap();
        }
        conn.execute_batch(SCHEMA_SQL).unwrap();
        ensure_ai_window_indexes(&conn).unwrap();
        conn
    }

    #[test]
    fn thread_crud_roundtrip() {
        let conn = test_conn();
        let id = create_thread(&conn, "翻译：hello", AiActionType::Translate, Some(3)).unwrap();
        assert!(id > 0);
        let id2 = create_thread(&conn, "对话", AiActionType::Chat, None).unwrap();
        assert!(id2 > id);

        let threads = list_threads(&conn).unwrap();
        assert_eq!(threads.len(), 2);
        // Most recently created first (same-second ties by id DESC).
        assert_eq!(threads[0].id, id2);
        assert_eq!(threads[0].title, "对话");
        assert_eq!(threads[0].action_type, AiActionType::Chat);
        assert_eq!(threads[0].book_id, None);
        assert_eq!(threads[1].id, id);
        assert_eq!(threads[1].action_type, AiActionType::Translate);
        assert_eq!(threads[1].book_id, Some(3));
        assert!(!threads[1].created_at.is_empty());
    }

    #[test]
    fn one_window_per_book_is_enforced() {
        let conn = test_conn();
        create_thread(&conn, "窗口", AiActionType::Chat, Some(7)).unwrap();
        let err = create_thread(&conn, "重复窗口", AiActionType::Chat, Some(7))
            .unwrap_err();
        assert!(err.to_string().contains("UNIQUE"), "{err}");
        // Multiple no-book windows are allowed.
        create_thread(&conn, "无书1", AiActionType::Chat, None).unwrap();
        create_thread(&conn, "无书2", AiActionType::Chat, None).unwrap();
        assert_eq!(list_threads(&conn).unwrap().len(), 3);
    }

    #[test]
    fn messages_roundtrip_and_bump_ordering() {
        let conn = test_conn();
        let id = create_thread(&conn, "t", AiActionType::Chat, None).unwrap();

        append_message(&conn, id, AiRole::User, "第一个问题", None, None).unwrap();
        append_message(&conn, id, AiRole::Assistant, "第一个回答", None, None).unwrap();
        append_message(&conn, id, AiRole::User, "追问", None, None).unwrap();

        let messages = list_messages(&conn, id).unwrap();
        assert_eq!(messages.len(), 3);
        // Conversation order.
        assert_eq!(messages[0].role, AiRole::User);
        assert_eq!(messages[0].content, "第一个问题");
        assert_eq!(messages[1].role, AiRole::Assistant);
        assert_eq!(messages[1].content, "第一个回答");
        assert_eq!(messages[2].role, AiRole::User);
        assert_eq!(messages[2].content, "追问");
        assert_eq!(messages[0].thread_id, id);

        // Other thread ids are isolated.
        assert!(list_messages(&conn, 999).unwrap().is_empty());
    }

    #[test]
    fn append_refreshes_latest_action_for_the_window_icon() {
        let conn = test_conn();
        let id = create_thread(&conn, "t", AiActionType::Translate, Some(1)).unwrap();
        append_message(&conn, id, AiRole::User, "q", None, None).unwrap();
        append_message(
            &conn,
            id,
            AiRole::User,
            "第二问",
            None,
            Some(AiActionType::Vision),
        )
        .unwrap();
        let threads = list_threads(&conn).unwrap();
        assert_eq!(threads[0].action_type, AiActionType::Vision);
        // A message without an action keeps the latest one.
        append_message(&conn, id, AiRole::Assistant, "a", None, None).unwrap();
        let threads = list_threads(&conn).unwrap();
        assert_eq!(threads[0].action_type, AiActionType::Vision);
    }

    #[test]
    fn delete_thread_removes_window_and_messages() {
        let conn = test_conn();
        let id = create_thread(&conn, "t", AiActionType::Chat, Some(5)).unwrap();
        append_message(&conn, id, AiRole::User, "q", None, None).unwrap();

        assert!(delete_thread(&conn, id).unwrap());
        assert!(list_threads(&conn).unwrap().is_empty());
        assert!(list_messages(&conn, id).unwrap().is_empty());
        // Deleting a missing window reports false.
        assert!(!delete_thread(&conn, 999).unwrap());
    }
}
