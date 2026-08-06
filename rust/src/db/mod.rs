//! Database subsystem.
//!
//! Schema (DDL) lives in [`schema`]; connection lifecycle in [`connection`].
//! Per-table repositories (`repository/`) will be filled in milestone M1+.
//! At the skeleton stage we only initialize the connection and apply the
//! full schema so the DB is structurally ready on first launch.

pub mod connection;
pub mod schema;

// Re-export the init entrypoint used by `api::init_core`, plus the shared
// connection accessor used by subsystem repositories.
pub use connection::{app_data_dir, db, db_path, init_database};
