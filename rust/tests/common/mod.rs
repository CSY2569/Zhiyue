//! Shared helpers for the integration test binaries (included via
//! `mod common;`). This file is not a test binary itself.

use std::path::PathBuf;

/// Fresh scratch directory under the temp dir (removed and recreated).
pub fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("rbwa_{tag}_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Upsert one `settings` KV row.
pub fn upsert_setting(conn: &rusqlite::Connection, key: &str, value: &str) {
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now')) \
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![key, value],
    )
    .unwrap();
}