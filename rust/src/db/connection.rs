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

use std::path::PathBuf;
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
///
/// Returns the resolved DB path (for display in the UI / logs).
pub fn init_database() -> AppResult<PathBuf> {
    let path = db_path()?;
    tracing::info!(?path, "opening SQLite database");

    let conn = Connection::open(&path)?;

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

    Ok(path)
}

/// Simple migration gate: write current version if absent, warn if stale.
///
/// Skeleton stage: only version 1 exists. Future migrations will chain here.
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
        Some(v) => {
            tracing::warn!(recorded = v, expected = SCHEMA_VERSION, "schema version mismatch -- migration not yet implemented");
        }
    }
    Ok(())
}
