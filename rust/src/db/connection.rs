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
/// by [`init_database_at`], read by subsystems via [`db`].
static DB: OnceLock<Mutex<Connection>> = OnceLock::new();

/// Override for the application data directory, set by [`init_database_at`]
/// to the database file's parent.
///
/// Production resolves it from the OS (`~/.local/share/RBWA`), and the DB
/// lives inside it, so the override matches the default. Tests instead point
/// the DB at a scratch dir (`init_core_with_db_path`): without this, every
/// *other* app-data path (covers/, documents/, ai_images/, models/) would
/// still resolve to the user's real directory -- so a test that deletes a
/// book also deleted the user's `covers/{id}.png` whenever the ids lined up.
static DATA_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// Guard holding the DB lock; returned by [`db`] and dropped by the caller.
type DbGuard<'a> = std::sync::MutexGuard<'a, Connection>;

/// Lock and borrow the shared connection. Blocks until the lock is free.
/// Panics if called before [`init_database_at`] (poisoned lock also panics).
pub fn db() -> DbGuard<'static> {
    DB.get()
        .expect("database not initialized -- init_database() not called")
        .lock()
        .expect("DB mutex poisoned")
}

/// Resolve the application data directory.
///
/// Production: `$XDG_DATA_HOME/RBWA` or `~/.local/share/RBWA`.
/// Created if missing. Falls back to `./RBWA_data` if `dirs` cannot resolve.
///
/// Android: `dirs::data_dir()` returns `None` (there is no XDG home), and the
/// process CWD is `/`, so the old fallback would try to create `/RBWA_data`.
/// The Dart layer therefore calls [`set_data_dir_override`] with
/// `getApplicationSupportDirectory()` before `init_core`; without it we fail
/// loudly instead of writing somewhere unwritable.
///
/// Once [`init_database_at`] has run, the initialized database's parent
/// directory wins (see [`DATA_DIR_OVERRIDE`]) -- so an isolated test DB keeps
/// covers / documents / screenshots / models inside the same scratch dir and
/// never touches the user's real data.
pub fn app_data_dir() -> AppResult<PathBuf> {
    if let Some(dir) = DATA_DIR_OVERRIDE.get() {
        std::fs::create_dir_all(dir)?;
        return Ok(dir.clone());
    }
    #[cfg(target_os = "android")]
    {
        return Err(crate::error::AppError::Internal(
            "Android 数据目录未初始化：启动时需先调用 init_core_with_data_dir".into(),
        ));
    }
    #[cfg(not(target_os = "android"))]
    {
        let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("./RBWA_data"));
        let dir = base.join("RBWA");
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }
}

/// Pin the app data directory for the rest of the process. Used by the
/// Android entrypoint (Dart passes `getApplicationSupportDirectory()`), and
/// by tests through [`init_database_at`].
///
/// Returns false when an override was already set (the first one wins, which
/// keeps a test-scoped dir from being replaced later in the same process).
pub fn set_data_dir_override(dir: PathBuf) -> bool {
    DATA_DIR_OVERRIDE.set(dir).is_ok()
}

/// Path to the SQLite database file.
pub fn db_path() -> AppResult<PathBuf> {
    Ok(app_data_dir()?.join("rbwa.db"))
}

/// Initialize the database: open connection, apply PRAGMAs, run schema DDL,
/// record schema version. Idempotent -- safe to call on every app start.
/// Uses an explicit path so tests can isolate their data from the user's
/// real database (`init_core_with_db_path`).
///
/// Returns the resolved DB path (for display in the UI / logs).
pub fn init_database_at(path: &Path) -> AppResult<PathBuf> {
    tracing::info!(?path, "opening SQLite database");

    // Pin the app data dir to the database's parent so every sibling path
    // (covers / documents / ai_images / models) stays next to this DB --
    // that is what keeps a test-scoped DB from touching the user's real data.
    if let Some(parent) = path.parent() {
        let _ = DATA_DIR_OVERRIDE.set(parent.to_path_buf());
    }

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

/// Whether [table] already has a column named [column].
///
/// Used to make the ALTER-based migrations idempotent: a database that was
/// interrupted after an ALTER committed but before its version row was
/// written (crash / OOM kill during an app update) would otherwise fail
/// forever with "duplicate column name" and never open again.
fn has_column(conn: &Connection, table: &str, column: &str) -> AppResult<bool> {
    // `PRAGMA table_info` cannot take bound parameters; the table names here
    // are all crate constants, never user input.
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let mut rows = stmt.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(1)?;
        if name.eq_ignore_ascii_case(column) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Migration gate: `SCHEMA_SQL` always reflects the latest schema (new
/// databases create it directly), while older databases walk a version chain
/// of ALTER statements here. Each migration runs exactly once, then the new
/// version is recorded.
///
/// The whole chain runs in ONE transaction: an interrupted upgrade must not
/// leave a half-applied schema (columns added but the version row missing),
/// which would make every later start re-run a non-idempotent ALTER and fail.
/// The individual ALTERs are additionally guarded by [has_column] so a
/// database already stuck in that half-applied state heals on the next start.
///
/// Chain:
///   1 -> 2: `annotations` gains the `text` column (M3: selected-text storage
///           for sidebar display + Markdown export, FEATURES 4.5).
///   2 -> 3: AI conversations become per-book windows (`ai_threads.book_id`).
///           Legacy test-era conversations are dropped (development phase;
///           authorized by the project owner). The window indexes are created
///           afterwards -- the column only exists once the ALTER has run.
fn migrate(conn: &Connection) -> AppResult<()> {
    let tx = conn.unchecked_transaction()?;
    migrate_body(&tx)?;
    tx.commit()?;
    Ok(())
}

fn migrate_body(conn: &Connection) -> AppResult<()> {
    // Record the current schema version after a successful migration.
    let record_version = |conn: &Connection| -> AppResult<()> {
        conn.execute(
            "INSERT INTO schema_version (version) VALUES (?1)",
            rusqlite::params![SCHEMA_VERSION],
        )?;
        Ok(())
    };

    let recorded: Option<u32> = conn
        .query_row("SELECT MAX(version) FROM schema_version", [], |row| {
            row.get(0)
        })
        .ok()
        .flatten();

    match recorded {
        None => {
            tracing::info!(version = SCHEMA_VERSION, "initial schema applied");
            record_version(conn)?;
        }
        Some(v) if v == SCHEMA_VERSION => {
            tracing::debug!(version = v, "schema already up to date");
        }
        Some(1) => {
            tracing::info!("migrating schema 1 -> 2 (annotations.text)");
            if !has_column(conn, "annotations", "text")? {
                conn.execute_batch("ALTER TABLE annotations ADD COLUMN text TEXT;")?;
            }
            record_version(conn)?;
        }
        Some(2) => {
            tracing::info!("migrating schema 2 -> 3 (per-book AI windows)");
            if !has_column(conn, "ai_threads", "book_id")? {
                conn.execute_batch("ALTER TABLE ai_threads ADD COLUMN book_id INTEGER;")?;
            }
            conn.execute_batch("DELETE FROM ai_messages; DELETE FROM ai_threads;")?;
            record_version(conn)?;
        }
        Some(3) => {
            tracing::info!("migrating schema 3 -> 4 (ai_messages.image_path)");
            if !has_column(conn, "ai_messages", "image_path")? {
                conn.execute_batch("ALTER TABLE ai_messages ADD COLUMN image_path TEXT;")?;
            }
            record_version(conn)?;
        }
        Some(4) => {
            tracing::info!(
                "migrating schema 4 -> 5 (full-text search: original_text + FTS triggers)"
            );
            if !has_column(conn, "page_text_index", "original_text")? {
                conn.execute_batch("ALTER TABLE page_text_index ADD COLUMN original_text TEXT;")?;
            }
            conn.execute_batch(
                "CREATE TRIGGER IF NOT EXISTS page_text_index_ai AFTER INSERT ON page_text_index BEGIN
                     INSERT INTO page_text_fts(rowid, raw_text) VALUES (new.rowid, new.raw_text);
                 END;
                 CREATE TRIGGER IF NOT EXISTS page_text_index_ad AFTER DELETE ON page_text_index BEGIN
                     INSERT INTO page_text_fts(page_text_fts, rowid, raw_text)
                         VALUES ('delete', old.rowid, old.raw_text);
                 END;
                 CREATE TRIGGER IF NOT EXISTS page_text_index_au AFTER UPDATE OF raw_text ON page_text_index BEGIN
                     INSERT INTO page_text_fts(page_text_fts, rowid, raw_text)
                         VALUES ('delete', old.rowid, old.raw_text);
                     INSERT INTO page_text_fts(rowid, raw_text) VALUES (new.rowid, new.raw_text);
                 END;",
            )?;
            record_version(conn)?;
        }
        Some(5) => {
            tracing::info!("migrating schema 5 -> 6 (ai_messages.action_type)");
            if !has_column(conn, "ai_messages", "action_type")? {
                conn.execute_batch("ALTER TABLE ai_messages ADD COLUMN action_type TEXT;")?;
            }
            record_version(conn)?;
        }
        Some(6) => {
            // v7 only ADDS tables (page_translation_cache /
            // translation_glossary): `execute_batch(SCHEMA_SQL)` above is
            // idempotent and has already created them on the old database,
            // so this branch just records the new version.
            tracing::info!("migrating schema 6 -> 7 (bilingual reading tables)");
            record_version(conn)?;
        }
        Some(7) => {
            // v8 DROPS the retired pipeline's per-page cache (translation
            // moved to an external translation engine; the rows have no
            // consumer). `translation_glossary` stays.
            tracing::info!("migrating schema 7 -> 8 (drop page_translation_cache)");
            conn.execute_batch("DROP TABLE IF EXISTS page_translation_cache;")?;
            record_version(conn)?;
        }
        Some(8) => {
            // v9 tags each text annotation with the pane it was made on
            // ('original' | 'translated'): the 对照 view's translated pane
            // gets the full mark set, and each pane renders only its own.
            tracing::info!("migrating schema 8 -> 9 (annotations.source)");
            if !has_column(conn, "annotations", "source")? {
                conn.execute_batch(
                    "ALTER TABLE annotations ADD COLUMN source TEXT NOT NULL DEFAULT 'original';",
                )?;
            }
            record_version(conn)?;
        }
        Some(9) => {
            // v10 only ADDS the text-level translation cache table; SCHEMA_SQL
            // above is idempotent and already created it on the old database,
            // so this branch just records the new version.
            tracing::info!("migrating schema 9 -> 10 (page_text_translation)");
            record_version(conn)?;
        }
        Some(10) => {
            // v11 adds the content hash used for import de-duplication.
            tracing::info!("migrating schema 10 -> 11 (books.content_hash)");
            conn.execute_batch("ALTER TABLE books ADD COLUMN content_hash TEXT;")?;
            record_version(conn)?;
        }
        Some(v) => {
            tracing::warn!(
                recorded = v,
                expected = SCHEMA_VERSION,
                "schema version mismatch -- migration not yet implemented"
            );
        }
    }

    // Per-book window indexes (v3). Must run after the ALTER above on old
    // databases; idempotent on fresh ones (SCHEMA_SQL creates the column).
    super::schema::ensure_ai_window_indexes(conn)?;
    // Content-hash index (v11). Unlike the AI window columns, this column is
    // brand new: a database mid-chain (the migration unit tests build v2/v4
    // fixtures and only record ONE version) has not run the v10 -> v11 ALTER
    // yet, so creating the index unconditionally would fail with
    // "no such column". The index is created on the next open after the
    // column exists.
    if has_column(conn, "books", "content_hash")? {
        super::schema::ensure_book_hash_index(conn)?;
    }
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
    fn migrate_heals_a_half_applied_upgrade() {
        // Simulates a crash between the ALTER and the version insert of an
        // earlier upgrade: the column exists but the recorded version does
        // not. Before the idempotent ALTERs this failed forever with
        // "duplicate column name", bricking the database.
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "DELETE FROM schema_version;
             INSERT INTO schema_version (version) VALUES (1);",
        )
        .unwrap();
        // v1 -> v2's column is already there.
        assert!(has_column(&conn, "annotations", "text").unwrap());

        migrate(&conn).expect("a half-applied migration must heal");

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);
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

    /// A v4-era database: the search tables exist but lack `original_text`
    /// and the external-content FTS triggers (M6 pre-migration state).
    fn v4_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "PRAGMA foreign_keys = ON;
             CREATE TABLE books (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                title         TEXT NOT NULL,
                original_path TEXT NOT NULL UNIQUE,
                stored_path   TEXT NOT NULL,
                file_type     TEXT NOT NULL,
                page_count    INTEGER NOT NULL DEFAULT 0,
                cover_path    TEXT,
                favorite      INTEGER NOT NULL DEFAULT 0,
                category_id   INTEGER,
                last_opened_at TEXT,
                imported_at   TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE ai_threads (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                title       TEXT NOT NULL,
                action_type TEXT NOT NULL,
                book_id     INTEGER,
                created_at  TEXT NOT NULL DEFAULT (datetime('now')),
                updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
             );
             CREATE TABLE page_text_index (
                book_id   INTEGER NOT NULL,
                page      INTEGER NOT NULL,
                source    TEXT NOT NULL,
                raw_text  TEXT NOT NULL,
                indexed_at TEXT NOT NULL DEFAULT (datetime('now')),
                PRIMARY KEY (book_id, page),
                FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
             );
             CREATE VIRTUAL TABLE page_text_fts USING fts5(
                raw_text,
                content='page_text_index',
                content_rowid='rowid',
                tokenize='unicode61'
             );
             CREATE TABLE schema_version (
                version    INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (datetime('now'))
             );
             INSERT INTO schema_version (version) VALUES (4);",
        )
        .unwrap();
        conn
    }

    #[test]
    fn migrate_v4_to_v5_wires_fulltext_triggers() {
        let conn = v4_db();
        migrate(&conn).unwrap();

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // original_text column added by the ALTER.
        let cols: Vec<String> = conn
            .prepare("PRAGMA table_info(page_text_index)")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(cols.contains(&"original_text".to_string()), "{cols:?}");

        // An insert into the content table propagates into the FTS index
        // (external content needs the triggers -- it does not sync itself).
        conn.execute(
            "INSERT INTO books (title, original_path, stored_path, file_type) \
             VALUES ('测试书', '/x.pdf', '/x.pdf', 'pdf')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO page_text_index (book_id, page, source, raw_text, original_text) \
             VALUES (1, 0, 'pdf', '量子 计算 入门', '量子计算入门')",
            [],
        )
        .unwrap();
        let hits: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM page_text_fts WHERE page_text_fts MATCH '\"量子\"'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(hits, 1, "FTS must see the inserted page");

        // Deleting the book cascades the content row AND its FTS entries.
        conn.execute("DELETE FROM books WHERE id = 1", []).unwrap();
        let remaining: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM page_text_fts WHERE page_text_fts MATCH '\"量子\"'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 0, "FTS entries must follow the cascade");

        // migrate is idempotent once up to date.
        migrate(&conn).unwrap();
    }

    /// A v6-era database (before bilingual reading): the v7 tables do not
    /// exist and version 6 is recorded -- what `init_database_at` sees when
    /// the app updates from a v6 build.
    fn v6_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "DROP TABLE translation_glossary;
             DELETE FROM schema_version;
             INSERT INTO schema_version (version) VALUES (6);",
        )
        .unwrap();
        conn
    }

    /// A v7-era database: the RETIRED pipeline's `page_translation_cache`
    /// exists (v7 added it) alongside the glossary.
    fn v7_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "CREATE TABLE page_translation_cache (
                 book_id         INTEGER NOT NULL,
                 page            INTEGER NOT NULL,
                 target_lang     TEXT NOT NULL,
                 provider        TEXT NOT NULL,
                 source_hash     TEXT NOT NULL,
                 result_json     TEXT NOT NULL,
                 created_at      TEXT NOT NULL DEFAULT (datetime('now')),
                 last_accessed_at TEXT NOT NULL DEFAULT (datetime('now')),
                 PRIMARY KEY (book_id, page, target_lang, provider)
             );
             DELETE FROM schema_version;
             INSERT INTO schema_version (version) VALUES (7);",
        )
        .unwrap();
        conn
    }

    #[test]
    fn migrate_v6_records_current_version_with_glossary_only() {
        let conn = v6_db();
        // `init_database_at` order: SCHEMA_SQL (idempotent) then migrate.
        conn.execute_batch(SCHEMA_SQL).unwrap();
        migrate(&conn).unwrap();

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Glossary table accepts entries; the retired pipeline's cache table
        // never (re)appears for a pre-v7 database.
        conn.execute(
            "INSERT INTO translation_glossary (source_term, target_term) \
             VALUES ('quantum', '量子')",
            [],
        )
        .unwrap();
        assert!(
            conn.query_row("SELECT COUNT(*) FROM page_translation_cache", [], |r| r
                .get::<_, i64>(0))
                .is_err(),
            "v8 must not carry the retired page cache"
        );

        // migrate is idempotent once up to date.
        migrate(&conn).unwrap();
    }

    /// A v8-era database: annotations exist WITHOUT the `source` column.
    fn v8_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        // Drop the v9 column to emulate the older shape (SQLite 3.35+).
        conn.execute_batch(
            "ALTER TABLE annotations DROP COLUMN source;
             DELETE FROM schema_version;
             INSERT INTO schema_version (version) VALUES (8);
             INSERT INTO books (id, title, original_path, stored_path, file_type) \
                 VALUES (1, 'b', '/o', '/s', 'pdf');
             INSERT INTO annotations (book_id, page, kind, text, rects) \
                 VALUES (1, 2, 'highlight', '旧标注', '[]');",
        )
        .unwrap();
        conn
    }

    /// A v10 database: latest table shapes minus the v11 content-hash column.
    fn v10_db() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        conn.execute_batch(
            "ALTER TABLE books DROP COLUMN content_hash;
             DELETE FROM schema_version;
             INSERT INTO schema_version (version) VALUES (10);
             INSERT INTO books (id, title, original_path, stored_path, file_type) \
                 VALUES (1, 'b', '/o', '/s', 'pdf');",
        )
        .unwrap();
        conn
    }

    #[test]
    fn migrate_v10_to_v11_adds_content_hash() {
        let conn = v10_db();
        migrate(&conn).unwrap();

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Column added; the existing row survives with a NULL hash (the
        // startup backfill fills it from the stored file).
        let hash: Option<String> = conn
            .query_row("SELECT content_hash FROM books WHERE id = 1", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(hash, None);

        // The de-dup index exists, so lookups on big libraries stay cheap.
        let indexes: Vec<String> = conn
            .prepare("PRAGMA index_list(books)")
            .unwrap()
            .query_map([], |r| r.get::<_, String>(1))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert!(
            indexes.contains(&"idx_books_content_hash".to_string()),
            "{indexes:?}"
        );
    }

    #[test]
    fn migrate_v8_to_v9_tags_annotations_with_pane() {
        let conn = v8_db();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        migrate(&conn).unwrap();

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // Pre-existing marks survive and read as the original pane.
        let (text, source): (String, String) = conn
            .query_row(
                "SELECT text, source FROM annotations WHERE book_id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(text, "旧标注");
        assert_eq!(source, "original");

        // New rows can carry the translated pane.
        conn.execute(
            "INSERT INTO annotations (book_id, page, kind, source, text, rects) \
             VALUES (1, 2, 'underline', 'translated', '译文', '[]')",
            [],
        )
        .unwrap();

        migrate(&conn).unwrap(); // idempotent
    }

    #[test]
    fn migrate_v7_to_v8_drops_retired_page_cache_and_keeps_glossary() {
        let conn = v7_db();
        conn.execute_batch(SCHEMA_SQL).unwrap();
        migrate(&conn).unwrap();

        let v: u32 = conn
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(v, SCHEMA_VERSION);

        // The retired pipeline's cache is dropped (translation moved to the
        // external translation engine; the rows had no consumer).
        assert!(
            conn.query_row("SELECT COUNT(*) FROM page_translation_cache", [], |r| r
                .get::<_, i64>(0))
                .is_err(),
            "page_translation_cache must be dropped by the v8 migration"
        );

        // The glossary survives the upgrade.
        conn.execute(
            "INSERT INTO translation_glossary (source_term, target_term) \
             VALUES ('quantum', '量子')",
            [],
        )
        .unwrap();

        // Idempotent once up to date.
        migrate(&conn).unwrap();
    }
}
