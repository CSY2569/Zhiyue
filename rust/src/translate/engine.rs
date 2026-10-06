//! Bundled RetainPDF translation engine (`retainpdf-pipeline` sidecar).
//!
//! The engine is a self-contained directory assembled by
//! `scripts/build_retain_engine.sh` and shipped inside the installation
//! bundle (`<exe_dir>/retainpdf`, mirroring the OCR models' resolution).
//! Layout:
//!
//! ```text
//! <engine_dir>/
//!   python/bin/python3.11        standalone CPython (uv-managed, symlinks dereferenced)
//!   site-packages/               retainpdf-pipeline + pinned deps (PYTHONPATH, no venv)
//!   bin/typst                    Typst 0.15.1
//!   typst-packages/preview/{cmarker,mitex}/   @preview packages (offline)
//!   fonts/SourceHanSerifSC-*.otf Source Han Serif SC (OFL)
//!   engine.json                  manifest (pipeline version / upstream commit / bundled)
//! ```
//!
//! The pipeline is invoked as `python -c "from retainpdf_pipeline... import
//! main; sys.exit(main())"` with `PYTHONPATH=site-packages`: console-script
//! shebangs and venv symlinks carry absolute paths that break under the
//! AppImage's per-run mount path (same reasoning as the retired BabelDOC
//! engine).
//!
//! Resolution order: test override > bundled > `RBWA_RETAIN_ENGINE_DIR` >
//! `{app_data_dir}/retainpdf`. v1 has no in-app installer: the engine is
//! either bundled with the package or assembled locally for development.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use crate::error::{AppError, AppResult};
use crate::models::translate::{EngineInstallEvent, EngineStatus, EngineStatusKind};

/// Test override for the engine directory (set once per process, mirroring
/// `db::connection::DATA_DIR_OVERRIDE`).
static ENGINE_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// Test-only: pin [engine_dir] to [dir] for the rest of the process.
pub fn set_engine_dir_override(dir: PathBuf) -> bool {
    ENGINE_DIR_OVERRIDE.set(dir).is_ok()
}

/// An engine shipped INSIDE the installation bundle.
pub fn bundled_engine_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?.join("retainpdf");
    dir.join("engine.json").is_file().then_some(dir)
}

/// The active engine directory (see module docs for the resolution order).
pub fn engine_dir() -> PathBuf {
    if let Some(dir) = ENGINE_DIR_OVERRIDE.get() {
        return dir.clone();
    }
    if let Some(bundled) = bundled_engine_dir() {
        return bundled;
    }
    if let Ok(dir) = std::env::var("RBWA_RETAIN_ENGINE_DIR") {
        return PathBuf::from(dir);
    }
    crate::db::app_data_dir()
        .unwrap_or_default()
        .join("retainpdf")
}

/// Whether the active engine comes from the installation bundle.
pub fn is_bundled() -> bool {
    bundled_engine_dir().is_some()
}

fn manifest_path() -> PathBuf {
    engine_dir().join("engine.json")
}

/// Engine manifest written by `scripts/build_retain_engine.sh`.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EngineManifest {
    /// `retainpdf-pipeline` version (e.g. "4.2.6").
    pub retainpdf_pipeline: String,
    /// Upstream commit the vendored pipeline came from (traceability).
    #[serde(default)]
    pub upstream_commit: String,
    #[serde(default)]
    pub built_at: String,
    /// Engine shipped inside the installation bundle.
    #[serde(default)]
    pub bundled: bool,
}

pub fn read_manifest() -> Option<EngineManifest> {
    let raw = std::fs::read_to_string(manifest_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn dir_size(dir: &Path) -> u64 {
    crate::db::repository::translate::dir_size(dir)
}

/// Total engine footprint (the assembled directory).
pub fn engine_disk_usage() -> i64 {
    dir_size(&engine_dir()) as i64
}

/// Interpreter running the pipeline (standalone CPython; no venv).
pub fn python_executable() -> PathBuf {
    engine_dir().join("python").join("bin").join("python3.11")
}

/// Command-line args invoking the pipeline CLI (module entry point).
pub fn pipeline_argv() -> [&'static str; 2] {
    [
        "-c",
        "import sys; from retainpdf_pipeline.entrypoints.console import main; sys.exit(main())",
    ]
}

/// Environment for pipeline child processes. [job_tmp] redirects every
/// cache/temp the pipeline may write into the job directory (never the
/// user's home).
pub fn runtime_env(job_tmp: &Path) -> Vec<(String, String)> {
    let engine = engine_dir();
    let s = |p: PathBuf| p.to_string_lossy().to_string();
    vec![
        ("PYTHONPATH".into(), s(engine.join("site-packages"))),
        ("TYPST_BIN".into(), s(engine.join("bin").join("typst"))),
        ("TYPST_PACKAGE_PATH".into(), s(engine.join("typst-packages"))),
        (
            "TYPST_PACKAGE_CACHE_PATH".into(),
            s(job_tmp.join("typst-package-cache")),
        ),
        (
            "RETAIN_PDF_FONT_PATH".into(),
            s(engine.join("fonts").join("SourceHanSerifSC-Regular.otf")),
        ),
        (
            "RETAIN_PDF_TITLE_BOLD_FONT_PATH".into(),
            s(engine.join("fonts").join("SourceHanSerifSC-Bold.otf")),
        ),
        (
            "RETAIN_PDF_TYPST_FONT_DIRS".into(),
            s(engine.join("fonts")),
        ),
        ("RETAIN_PDF_TYPST_FONT_FAMILY".into(), "Source Han Serif SC".into()),
        ("PYTHONUNBUFFERED".into(), "1".into()),
        // Engine scratch (translation-unit / domain / typography caches):
        // without this the pipeline anchors `data/` at its cwd.
        ("OUTPUT_ROOT".into(), s(job_tmp.join("output"))),
        ("TMPDIR".into(), s(job_tmp.join("tmp"))),
        ("XDG_CACHE_HOME".into(), s(job_tmp.join("xdg-cache"))),
        ("HOME".into(), s(job_tmp.join("home"))),
    ]
}

// =============================================================================
// Status
// =============================================================================

/// Status derived from disk (the manifest's presence is the authority).
fn probe_status() -> EngineStatus {
    match read_manifest() {
        Some(m) => EngineStatus {
            kind: EngineStatusKind::Installed,
            phase: String::new(),
            progress: 1.0,
            version: format!("retainpdf-pipeline {}", m.retainpdf_pipeline),
            size_bytes: engine_disk_usage(),
            error: None,
            bundled: m.bundled || is_bundled(),
        },
        None => EngineStatus {
            kind: EngineStatusKind::NotInstalled,
            phase: String::new(),
            progress: 0.0,
            version: String::new(),
            size_bytes: 0,
            error: None,
            bundled: false,
        },
    }
}

/// Current engine status for the settings card (probes disk each call).
pub fn get_engine_status() -> EngineStatus {
    probe_status()
}

/// v1 has no in-app installer (the engine ships with the package). The
/// install stream reports this as a final error event so the settings card
/// shows an actionable message instead of a hang.
pub async fn install_engine(mut on_event: impl FnMut(EngineInstallEvent) + Send + 'static) -> AppResult<()> {
    let status = probe_status();
    if status.kind == EngineStatusKind::Installed {
        on_event(EngineInstallEvent {
            phase: "完成".into(),
            progress: 1.0,
            detail: "引擎已就绪".into(),
            finished: true,
            error: None,
        });
        return Ok(());
    }
    on_event(EngineInstallEvent {
        phase: "失败".into(),
        progress: 0.0,
        detail: String::new(),
        finished: true,
        error: Some(missing_engine_message()),
    });
    Err(AppError::Internal(missing_engine_message()))
}

/// Cancellation is a no-op: there is no install to cancel (kept for the
/// settings card's existing stream wiring).
pub fn cancel_install() {}

/// In-app uninstall is not supported: the bundled engine ships with the
/// package and a development engine is managed by its build script.
pub fn uninstall_engine() -> AppResult<()> {
    Err(AppError::Internal(
        "引擎随安装包内置或由构建脚本管理，应用内不提供卸载".into(),
    ))
}

fn missing_engine_message() -> String {
    format!(
        "未找到翻译引擎（{}）。请使用内置引擎的安装包，或用 \
         scripts/build_retain_engine.sh 组装后设置 RBWA_RETAIN_ENGINE_DIR。",
        engine_dir().display()
    )
}

/// Whether the engine directory looks runnable (manifest + interpreter).
pub fn is_ready() -> bool {
    read_manifest().is_some() && python_executable().is_file()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_parses_and_reports_version() {
        let dir = std::env::temp_dir().join(format!("rbwa_retain_engine_manifest_{}", std::process::id()));
        std::fs::create_dir_all(dir.join("python/bin")).unwrap();
        std::fs::write(
            dir.join("engine.json"),
            r#"{"retainpdf_pipeline":"4.2.6","upstream_commit":"d365ed8","built_at":"2026-10-06T00:00:00Z","bundled":true}"#,
        )
        .unwrap();
        std::fs::write(dir.join("python/bin/python3.11"), b"#!/bin/sh\n").unwrap();

        assert!(set_engine_dir_override(dir.clone()));
        let m = read_manifest().expect("manifest");
        assert_eq!(m.retainpdf_pipeline, "4.2.6");
        assert_eq!(m.upstream_commit, "d365ed8");
        assert!(m.bundled);
        let s = get_engine_status();
        assert_eq!(s.kind, EngineStatusKind::Installed);
        assert_eq!(s.version, "retainpdf-pipeline 4.2.6");
        assert!(s.bundled);
        assert!(is_ready());
        assert!(python_executable().ends_with("python3.11"));

        let env = runtime_env(Path::new("/tmp/job"));
        let get = |k: &str| env.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone());
        assert!(get("PYTHONPATH").unwrap().ends_with("site-packages"));
        assert_eq!(get("TYPST_BIN").unwrap(), dir.join("bin/typst").to_string_lossy());
        assert_eq!(get("RETAIN_PDF_TYPST_FONT_FAMILY").unwrap(), "Source Han Serif SC");
        assert_eq!(get("PYTHONUNBUFFERED").unwrap(), "1");
        assert!(get("TMPDIR").unwrap().starts_with("/tmp/job"));
        assert_eq!(get("OUTPUT_ROOT").unwrap(), "/tmp/job/output");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn uninstall_is_refused_with_guidance() {
        let err = uninstall_engine().unwrap_err().to_string();
        assert!(err.contains("不提供卸载"), "{err}");
    }
}