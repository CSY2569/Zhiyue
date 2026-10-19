//! `settings` KV repository.
//!
//! The settings table is a plain key/value store: theme choice, AI config
//! JSON, translation config, search index markers and pinned book ids all
//! live here. Centralizing the SQL keeps every caller on the same upsert
//! semantics and keeps raw SQL out of `api.rs`.
//!
//! Functions take a borrowed [`Connection`]: callers already holding the
//! process-wide guard must not call `db::db()` again (the handle is a
//! non-reentrant mutex).

use rusqlite::{params, Connection};
use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::error::AppResult;

/// Raw value for [key], or None when absent.
pub fn get_raw(conn: &Connection, key: &str) -> Option<String> {
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        params![key],
        |row| row.get::<_, String>(0),
    )
    .ok()
}

/// Upsert a raw value.
pub fn set_raw(conn: &Connection, key: &str, value: &str) -> AppResult<()> {
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now'))
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        params![key, value],
    )?;
    Ok(())
}

/// Deserialize the JSON value stored at [key]; malformed or absent JSON
/// yields None (callers fall back to their default).
pub fn get_json<T: DeserializeOwned>(conn: &Connection, key: &str) -> Option<T> {
    get_raw(conn, key).and_then(|raw| serde_json::from_str(&raw).ok())
}

/// Serialize [value] as JSON and upsert it.
pub fn set_json<T: Serialize>(conn: &Connection, key: &str, value: &T) -> AppResult<()> {
    let raw = serde_json::to_string(value)?;
    set_raw(conn, key, &raw)
}

/// Whether [key] exists (index-ready / failed markers).
pub fn exists(conn: &Connection, key: &str) -> bool {
    conn.query_row(
        "SELECT 1 FROM settings WHERE key = ?1",
        params![key],
        |_| Ok(()),
    )
    .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn conn() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE settings (
                 key TEXT PRIMARY KEY,
                 value TEXT NOT NULL,
                 updated_at TEXT NOT NULL DEFAULT (datetime('now'))
             );",
        )
        .unwrap();
        conn
    }

    #[test]
    fn raw_roundtrip_and_upsert() {
        let conn = conn();
        assert!(get_raw(&conn, "k").is_none());
        set_raw(&conn, "k", "v1").unwrap();
        assert_eq!(get_raw(&conn, "k").as_deref(), Some("v1"));
        set_raw(&conn, "k", "v2").unwrap();
        assert_eq!(get_raw(&conn, "k").as_deref(), Some("v2"));
        assert!(exists(&conn, "k"));
        assert!(!exists(&conn, "missing"));
    }

    #[test]
    fn json_roundtrip_and_malformed_value() {
        #[derive(Debug, PartialEq, serde::Serialize, serde::Deserialize)]
        struct Config {
            value: i32,
        }
        let conn = conn();
        set_json(&conn, "cfg", &Config { value: 7 }).unwrap();
        assert_eq!(get_json::<Config>(&conn, "cfg"), Some(Config { value: 7 }));

        set_raw(&conn, "bad", "{not json").unwrap();
        assert!(get_json::<Config>(&conn, "bad").is_none());
        assert!(get_json::<Config>(&conn, "absent").is_none());
    }
}
