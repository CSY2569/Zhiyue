//! SQLite connection management for RBWA.
//!
//! Responsibilities:
//!   - Resolve the application data directory (`~/.local/share/RBWA/` on Linux).
//!   - Open / create `rbwa.db` with WAL + foreign keys (FEATURES 9.2.1).
//!   - Apply the schema from [`super::schema`] on first run.
//!   - Gate migrations via the `schema_version` table.
//!
//! The connection is held by a global [`DbHandle`] registered through
//! `flutter_rust_bridge`, so Flutter calls into Rust operate on the live DB
//! without reopening it each call.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use rusqlite::Connection;

use super::schema::{PRAGMAS, SCHEMA_SQL, SCHEMA_VERSION};
use crate::error::AppResult;

/// Global DB connection behind a Mutex. rusqlite::Connection is not `Sync`
/// (internal RefCell), so all access serializes through this lock. Set once
/// by [`init_database`], read by subsystems via [`db`].
static DB: OnceLock<Mutex<Connection>> = OnceLock::new();

/// Guard holding the DB lock; returned by [`db`] and dropped by the caller.
pub type DbGuard<'a> = std::sync::MutexGuard<'a, Connection>;

/// Lock and borrow the shared connection. Blocks until the lock is free.
/// Panics if called before [`init_database`] (poisoned lock also panics).
pub fn db() -> DbGuard<'static> {
    DB.get()
        .expect("database not initialized -- init_database() not called")
        .lock()
        .expect("DB mutex poisoned")
}

/// Resolve the application data directory.
///
/// Linux: `$XDG_DATA_HOME/RBWA` or `~/.local/share/RBWA`.
/// Created if missing. Falls back to `./RBWA_data` if `dirs` cannot resolve.
pub fn app_data_dir() -> AppResult<PathBuf> {
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("./RBWA_data"));
    let dir = base.join("RBWA");
    std::fs::create_dir_all(&dir)?;
    Ok(dir)
}

/// Path to the SQLite database file.
pub fn db_path() -> AppResult<PathBuf> {
    Ok(app_data_dir()?.join("rbwa.db"))
}

/// Initialize the database: open connection, apply PRAGMAs, run schema DDL,
/// record schema version. Idempotent -- safe to call on every app start.
/// Uses the default app-data path (production).
///
/// Returns the resolved DB path (for display in the UI / logs).
pub fn init_database() -> AppResult<PathBuf> {
    init_database_at(&db_path()?)
}

/// Initialize the database at an explicit path. Used by integration tests to
/// isolate test data from the user's real database (`init_core_with_db_path`).
pub fn init_database_at(path: &Path) -> AppResult<PathBuf> {
    tracing::info!(?path, "opening SQLite database");

    let conn = Connection::open(path)?;

    // Apply PRAGMAs (WAL, foreign keys, synchronous).
    for pragma in PRAGMAS {
        conn.execute_batch(pragma)?;
    }

    // Run schema DDL (idempotent via IF NOT EXISTS).
    conn.execute_batch(SCHEMA_SQL)?;

    // Record / verify schema version.
    migrate(&conn)?;

    // Install the connection globally behind a Mutex. If init runs twice
    // (shouldn't), the second connection is dropped silently.
    let _ = DB.set(Mutex::new(conn));

    Ok(path.to_path_buf())
}

/// Migration gate: `SCHEMA_SQL` always reflects the latest schema (new
/// databases create it directly), while older databases walk a version chain
/// of ALTER statements here. Each migration runs exactly once, then the new
/// version is recorded.
///
/// Chain:
///   1 -> 2: `annotations` gains the `text` column (M3: selected-text storage
///           for sidebar display + Markdown export, FEATURES 4.5).
///   2 -> 3: AI conversations become per-book windows (`ai_threads.book_id`).
///           Legacy test-era conversations are dropped (development phase;
///           authorized by the project owner). The window indexes are created
///           afterwards -- the column only exists once the ALTER has run.
fn migrate(conn: &Connection) -> AppResult<()> {
    let recorded: Option<u32> = conn
        .query_row(
            "SELECT MAX(version) FROM schema_version",
            [],
            |row| row.get(0),
        )
        .ok()
        .flatten();

    match recorded {
        None => {
            tracing::info!(version = SCHEMA_VERSION, "initial schema applied");
            conn.execute(
                "INSERT INTO schema_version (version) VALUES (?1)",
                rusqlite::params![SCHEMA_VERSION],
            )?;
        }
        Some(v) if v == SCHEMA_VERSION => {
            tracing::debug!(version = v, "schema already up to date");
        }
        Some(1) => {
            tracing::info!("migrating schema 1 -> 2 (annotations.text)");
            conn.execute_batch(
                "ALTER TABLE annotations ADD COLUMN text TEXT;",
            )?;
            conn.execute(
                "INSERT INTO schema_version (version) VALUES (?1)",
                rusqlite::params![SCHEMA_VERSION],
            )?;
        }
        Some(2) => {
            tracing::info!("migrating schema 2 -> 3 (per-book AI windows)");
            conn.execute_batch(
                "ALTER TABLE ai_threads ADD COLUMN book_id INTEGER; \
                 DELETE FROM ai_messages; \
                 DELETE FROM ai_threads;",
            )?;
            conn.execute(
                "INSERT INTO schema_version (version) VALUES (?1)",
                rusqlite::params![SCHEMA_VERSION],
            )?;
        }
        Some(v) => {
            tracing::warn!(recorded = v, expected = SCHEMA_VERSION, "schema version mismatch -- migration not yet implemented");
        }
    }

    // Per-book window indexes (v3). Must run after the ALTER above on old
    // databases; idempotent on fresh ones (SCHEMA_SQL creates the column).
    super::schema::ensure_ai_window_indexes(conn)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::{params, Connection};

    /// A v2-era database: old `ai_threads` schema (no book_id), a legacy
    /// test conversation, and version 2 recorded -- what `migrate` sees when
    /// the app updates to v3.
    fn v2_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE ai_threads (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                title       TEXT NOT NULL,
                action_type TEXT NOT NULL,
                created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE ai_messages (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                thread_id   INTEGER NOT NULL,
                role        TEXT NOT NULL,
                content     TEXT NOT NULL,
                created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                FOREIGN KEY (thread_id) REFERENCES ai_threads(id) ON DELETE CASCADE
             );
             CREATE TABLE schema_version (
                version    INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             INSERT INTO schema_version (version) VALUES (2);
             INSERT INTO ai_threads (title, action_type) VALUES ('翻译：旧数据', 'translate');
             INSERT INTO ai_threads (title, action_type) VALUES ('对话：旧数据', 'chat');",
        )
        .unwrap();
        let id1: i64 = conn
            .query_row("SELECT id FROM ai_threads LIMIT 1", [], |r| r.get(0))
            .unwrap();
        conn.execute(
            "INSERT INTO ai_messages (thread_id, role, content) VALUES (?1, 'user', '旧问题')",
            params![id1],
        )
        .unwrap();
        conn
    }

    #[test]
    fn fresh_db_gets_book_id_and_window_indexes() {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        migrate(&conn).unwrap();

        // book_id comes from SCHEMA_SQL on fresh databases.
        let cols: Vec<String> = conn
            .prepare("PRAGMA table_info(ai_threads)")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(cols.contains(&"book_id".to_string()), "{cols:?}");

        // Both window indexes are installed by migrate.
        let idx: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND \
                 name IN ('idx_ai_threads_book', 'uq_ai_threads_book')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(idx, 2);
    }

    #[test]
    fn migrate_v2_to_v3_adds_book_id_and_clears_legacy_conversations() {
        let conn = v2_db();
        migrate(&conn).unwrap();

        // Version recorded.
        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Legacy test-era conversations are dropped (authorized wipe).
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM ai_threads", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
            0
        );
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM ai_messages", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
            0
        );

        // book_id works, and one window per book is enforced by the index.
        conn.execute(
            "INSERT INTO ai_threads (title, action_type, book_id) \
             VALUES ('窗口', 'chat', 7)",
            [],
        )
        .unwrap();
        let err = conn
            .execute(
                "INSERT INTO ai_threads (title, action_type, book_id) \
                 VALUES ('重复', 'chat', 7)",
                [],
            )
            .unwrap_err();
        assert!(err.to_string().contains("UNIQUE"), "{err}");
        // Multiple no-book windows remain allowed.
        conn.execute(
            "INSERT INTO ai_threads (title, action_type) VALUES ('无书1', 'chat')",
            [],
        )
        .unwrap();

        // migrate is idempotent once up to date.
        migrate(&conn).unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM ai_threads", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
            2
        );
    }
}
