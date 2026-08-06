//! Flutter -> Rust command surface (flutter_rust_bridge v2).
//!
//! This module is the single aggregation point for all functions exported to
//! Dart. Each subsystem exposes higher-level commands here; the Dart side
//! never calls into `pdf` / `ocr` / `ai` / `search` / `db` directly. This
//! keeps the FFI boundary narrow and the architecture loosely coupled
//! (TECH_ROADMAP §1: "命令调用 -> Rust").
//!
//! Skeleton stage exports:
//!   - `ping()`           : verify the FRB pipeline returns "pong".
//!   - `init_core()`      : open SQLite, apply schema, set up logging.
//!   - `app_version()`    : return crate version for the About UI.
//!   - `db_path()`        : return the resolved DB path for display.
//!
//! Subsystem commands (book import, render, ocr, ai, search) are added per
//! milestone, each delegating to the relevant service trait.

use std::sync::OnceLock;

use crate::db;
// `pub use` so the generated `frb_generated.rs` (which does `use crate::api::*`)
// can resolve these type names in its own scope.
pub use crate::error::{AppError, AppResult};

/// Global flag set once `init_core` succeeds. Cheap to read from Dart-side
/// polling (skeleton only; M1+ replaces with a proper state machine).
static INITIALIZED: OnceLock<bool> = OnceLock::new();

/// Pipeline smoke test. Flutter calls this on startup to confirm the FRB
/// bridge is wired correctly; the UI shows the returned string.
pub fn ping() -> String {
    "pong".to_string()
}

/// Crate version, surfaced in the About / settings UI.
pub fn app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Result of core initialization, returned to Flutter.
pub struct InitResult {
    pub ok: bool,
    /// Resolved database file path (for display / diagnostics).
    pub db_path: String,
    /// Schema version applied.
    pub schema_version: u32,
    /// Human-readable error if initialization failed.
    pub error: Option<String>,
}

/// Initialize the Rust core. Called exactly once on app startup, before any
/// other command. Opens SQLite, applies the schema (idempotent), and sets up
/// tracing. Safe to call again; returns the cached result.
pub fn init_core() -> InitResult {
    if INITIALIZED.get().is_some() {
        return InitResult {
            ok: true,
            db_path: db::db_path()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_default(),
            schema_version: db::schema::SCHEMA_VERSION,
            error: None,
        };
    }

    match try_init() {
        Ok(path) => {
            let _ = INITIALIZED.set(true);
            InitResult {
                ok: true,
                db_path: path.to_string_lossy().to_string(),
                schema_version: db::schema::SCHEMA_VERSION,
                error: None,
            }
        }
        Err(e) => InitResult {
            ok: false,
            db_path: String::new(),
            schema_version: 0,
            error: Some(e.to_string()),
        },
    }
}

fn try_init() -> AppResult<std::path::PathBuf> {
    // Structured logging to stderr; tune via RUST_LOG.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .try_init();

    tracing::info!(version = app_version(), "initializing RBWA core");

    let path = db::init_database()?;
    tracing::info!(?path, "database ready");
    Ok(path)
}

/// Read a setting value by key (skeleton: direct KV read).
/// Returns empty string if the key is absent. Real subsystem repos wrap
/// this in M1; for the skeleton an empty string sentinel is sufficient.
///
/// # Panics
/// Panics if called before `init_core()` (programming error).
pub fn get_setting(key: String) -> Option<String> {
    let conn = db::db();
    conn.query_row(
        "SELECT value FROM settings WHERE key = ?1",
        rusqlite::params![key],
        |row| row.get::<_, String>(0),
    )
    .ok()
}

/// Write a setting value by key (upsert). Skeleton helper for theme etc.
/// Returns 1 on success, 0 on failure.
///
/// # Panics
/// Panics if called before `init_core()` (programming error).
pub fn set_setting(key: String, value: String) -> i32 {
    let conn = db::db();
    conn.execute(
        "INSERT INTO settings (key, value, updated_at) VALUES (?1, ?2, datetime('now'))
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
        rusqlite::params![key, value],
    )
    .map(|_| 1)
    .unwrap_or(0)
}

/// Count tables in the DB -- used by the skeleton's diagnostics page to
/// prove the schema was applied. Expects 10 content tables + 1 FTS + version.
///
/// # Panics
/// Panics if called before `init_core()` (programming error).
pub fn table_count() -> i64 {
    let conn = db::db();
    conn.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'",
        [],
        |row| row.get(0),
    )
    .unwrap_or(-1)
}
