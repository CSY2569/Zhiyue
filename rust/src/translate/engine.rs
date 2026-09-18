//! Downloadable translation engine (BabelDOC + pdf2zh-next).
//!
//! The engine is an OPT-IN download (about 1GB): a uv-managed Python 3.12
//! environment under `{app_data_dir}/babeldoc` plus BabelDOC's model/font
//! assets (which live in BabelDOC's own cache, `~/.cache/babeldoc`). Nothing
//! ships inside the app bundle.
//!
//! Install steps (idempotent -- each skips when its output exists):
//!   1. download the pinned uv binary (GitHub release, SHA-256 verified);
//!   2. `uv venv --python 3.12` (uv provisions CPython itself);
//!   3. `uv pip install pdf2zh-next==<pin>` (pulls BabelDOC transitively);
//!   4. `babeldoc --warmup` -- downloads + SHA3-verifies fonts/models/cmaps;
//!   5. write `engine.json` (versions / install date / recorded size).
//!
//! Testability: `RBWA_BABELDOC_DIR` overrides the environment directory and
//! `RBWA_BABELDOC_MOCK_SCRIPT` replaces the real steps with a shell script
//! (dry-run smoke in CI; the real install is exercised manually).

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use sha2::{Digest, Sha256};

use crate::error::{AppError, AppResult};
use crate::models::translate::{EngineInstallEvent, EngineStatus, EngineStatusKind};

/// Pinned uv release (the installer's only direct download).
const UV_VERSION: &str = "0.12.16";
/// Pinned pdf2zh-next (its BabelDOC dependency is pinned by the package).
const PDF2ZH_NEXT_VERSION: &str = "2.9.0";
/// Python the engine environment runs on (BabelDOC requires >=3.10,<3.14).
const PYTHON_VERSION: &str = "3.12";

/// Install-phase progress bands (whole-install fraction).
const P_UV_START: f64 = 0.0;
const P_UV_SPAN: f64 = 0.10;
const P_VENV: f64 = 0.12;
const P_PIP: f64 = 0.25;
const P_WARMUP: f64 = 0.60;

fn uv_asset_url() -> String {
    format!(
        "https://github.com/astral-sh/uv/releases/download/{UV_VERSION}/uv-x86_64-unknown-linux-gnu.tar.gz"
    )
}

/// Test/dry-run override for the engine directory (set once per process,
/// mirroring `db::connection::DATA_DIR_OVERRIDE`) -- the env var below serves
/// manual smoke runs, the OnceLock keeps parallel tests race-free.
static ENGINE_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();
/// Same for BabelDOC's asset cache: tests must never touch the user's real
/// `~/.cache/babeldoc` (uninstall deletes it).
static CACHE_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// `{app_data_dir}/babeldoc` (override: `RBWA_BABELDOC_DIR`).
pub fn engine_dir() -> PathBuf {
    if let Some(dir) = ENGINE_DIR_OVERRIDE.get() {
        return dir.clone();
    }
    if let Ok(dir) = std::env::var("RBWA_BABELDOC_DIR") {
        return PathBuf::from(dir);
    }
    crate::db::app_data_dir()
        .unwrap_or_default()
        .join("babeldoc")
}

fn manifest_path() -> PathBuf {
    engine_dir().join("engine.json")
}
fn uv_binary() -> PathBuf {
    engine_dir().join("bin").join("uv")
}
fn venv_dir() -> PathBuf {
    engine_dir().join("venv")
}
fn venv_python() -> PathBuf {
    venv_dir().join("bin").join("python")
}
fn venv_babeldoc() -> PathBuf {
    venv_dir().join("bin").join("babeldoc")
}

/// BabelDOC's own asset cache (fonts/models/cmaps; `babeldoc/const.py`
/// hardcodes `~/.cache/babeldoc`).
fn babeldoc_cache_dir() -> PathBuf {
    if let Some(dir) = CACHE_DIR_OVERRIDE.get() {
        return dir.clone();
    }
    std::env::var("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".cache")
        })
        .join("babeldoc")
}

/// Install-date / version manifest written as the last step.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EngineManifest {
    pub pdf2zh_next: String,
    pub installed_at: String,
    /// Whether BabelDOC's asset cache already existed before WE installed
    /// (a user running pdf2zh themselves). Uninstall only deletes the cache
    /// when we created it, so a pre-existing cache is never nuked.
    #[serde(default)]
    pub cache_preexisting: bool,
}

fn read_manifest() -> Option<EngineManifest> {
    let raw = std::fs::read_to_string(manifest_path()).ok()?;
    serde_json::from_str(&raw).ok()
}

fn dir_size(dir: &Path) -> u64 {
    crate::db::repository::translate::dir_size(dir)
}

/// Total engine footprint: the managed environment + BabelDOC's asset cache.
pub fn engine_disk_usage() -> i64 {
    (dir_size(&engine_dir()) + dir_size(&babeldoc_cache_dir())) as i64
}

// =============================================================================
// Install state machine
// =============================================================================

static INSTALL_STATE: OnceLock<Mutex<EngineStatus>> = OnceLock::new();
static CANCEL: AtomicBool = AtomicBool::new(false);
/// Whether BabelDOC's asset cache existed before this install started
/// (recorded in the manifest; uninstall then leaves a pre-existing cache).
static CACHE_PREEXISTING: AtomicBool = AtomicBool::new(false);

fn state() -> &'static Mutex<EngineStatus> {
    INSTALL_STATE.get_or_init(|| Mutex::new(probe_status()))
}

/// Status derived from disk (the authority: the manifest's presence).
fn probe_status() -> EngineStatus {
    match read_manifest() {
        Some(m) => EngineStatus {
            kind: EngineStatusKind::Installed,
            phase: String::new(),
            progress: 1.0,
            version: m.pdf2zh_next,
            size_bytes: engine_disk_usage(),
            error: None,
        },
        None => EngineStatus {
            kind: EngineStatusKind::NotInstalled,
            phase: String::new(),
            progress: 0.0,
            version: String::new(),
            size_bytes: engine_disk_usage(),
            error: None,
        },
    }
}

/// Current engine status for the settings card.
pub fn get_engine_status() -> EngineStatus {
    let mut s = state().lock().unwrap();
    // An in-flight install keeps its live progress; otherwise re-probe disk
    // (the manifest may have appeared/disappeared outside this process).
    if s.kind != EngineStatusKind::Installing {
        *s = probe_status();
    }
    s.clone()
}

fn set_state(f: impl FnOnce(&mut EngineStatus)) {
    if let Ok(mut s) = state().lock() {
        f(&mut s);
    }
}

/// Requests cancellation of a running install (kills the current child).
pub fn cancel_install() {
    CANCEL.store(true, Ordering::SeqCst);
}

/// Removes the managed environment (and BabelDOC's asset cache when WE
/// created it). Refused while a book is translating or an install is running.
pub fn uninstall_engine() -> AppResult<()> {
    if get_engine_status().kind == EngineStatusKind::Installing {
        return Err(AppError::Internal("引擎正在安装，无法卸载".into()));
    }
    if crate::translate::is_translating_any() {
        return Err(AppError::Internal("有翻译任务进行中，无法卸载引擎".into()));
    }
    // A pre-existing cache (user runs pdf2zh themselves) is left alone.
    let cache_preexisting = read_manifest()
        .map(|m| m.cache_preexisting)
        .unwrap_or(false);
    let dir = engine_dir();
    if dir.exists() {
        std::fs::remove_dir_all(&dir)?;
    }
    if !cache_preexisting {
        let cache = babeldoc_cache_dir();
        if cache.exists() {
            std::fs::remove_dir_all(&cache)?;
        }
    }
    set_state(|s| *s = probe_status());
    Ok(())
}

// =============================================================================
// Install
// =============================================================================

/// Runs the install, streaming events. Idempotent: completed steps are
/// skipped, so a retry after a failure resumes where it stopped.
pub async fn install_engine(mut on_event: impl FnMut(EngineInstallEvent) + Send + 'static) -> AppResult<()> {
    if get_engine_status().kind == EngineStatusKind::Installing {
        return Err(AppError::Internal("引擎已在安装中".into()));
    }
    CANCEL.store(false, Ordering::SeqCst);
    CACHE_PREEXISTING.store(babeldoc_cache_dir().exists(), Ordering::SeqCst);
    set_state(|s| {
        *s = EngineStatus {
            kind: EngineStatusKind::Installing,
            phase: "准备".into(),
            progress: 0.0,
            version: String::new(),
            size_bytes: 0,
            error: None,
        };
    });

    let result = tokio::task::spawn_blocking(move || {
        let r = run_install(&mut on_event);
        // Failure is reported on the stream as a final event (the Dart side
        // reads `error` from the event, mirroring the retired pipeline's
        // sentinel pattern), then returned for logging.
        if let Err(e) = &r {
            on_event(EngineInstallEvent {
                phase: "失败".into(),
                progress: 0.0,
                detail: e.to_string(),
                finished: true,
                error: Some(e.to_string()),
            });
        }
        r
    })
    .await;
    match result {
        Ok(Ok(())) => {
            set_state(|s| *s = probe_status());
            Ok(())
        }
        Ok(Err(e)) => {
            let msg = e.to_string();
            set_state(|s| {
                s.kind = EngineStatusKind::Failed;
                s.error = Some(msg.clone());
                s.phase = String::new();
            });
            Err(e)
        }
        Err(e) => {
            let msg = format!("安装任务失败: {e}");
            set_state(|s| {
                s.kind = EngineStatusKind::Failed;
                s.error = Some(msg.clone());
                s.phase = String::new();
            });
            Err(AppError::Internal(msg))
        }
    }
}

fn emit(
    on_event: &mut impl FnMut(EngineInstallEvent),
    phase: &str,
    progress: f64,
    detail: impl Into<String>,
) {
    let detail = detail.into();
    set_state(|s| {
        s.phase = phase.to_string();
        s.progress = progress;
    });
    on_event(EngineInstallEvent {
        phase: phase.to_string(),
        progress,
        detail,
        finished: false,
        error: None,
    });
}

fn run_install(on_event: &mut impl FnMut(EngineInstallEvent)) -> AppResult<()> {
    // Dry-run hook: CI / smoke runs replace all real steps with a script.
    if let Ok(script) = std::env::var("RBWA_BABELDOC_MOCK_SCRIPT") {
        return run_mock(&script, on_event);
    }

    std::fs::create_dir_all(engine_dir())?;

    // --- step 1: uv binary -------------------------------------------------
    if !uv_binary().exists() {
        emit(on_event, "下载 uv", P_UV_START, "下载 uv 运行时…");
        download_uv(|frac, done, total| {
            emit(
                on_event,
                "下载 uv",
                P_UV_START + frac * P_UV_SPAN,
                format!("{done} / {total} 字节"),
            );
        })?;
    }
    check_cancel()?;

    // --- step 2: python environment ---------------------------------------
    if !venv_python().exists() {
        emit(on_event, "创建 Python 环境", P_VENV, "uv venv (Python 3.12)…");
        run_child(
            &uv_binary(),
            &["venv", "--python", PYTHON_VERSION],
            &[],
            &[],
            Some(venv_dir().as_path()),
            "创建 Python 环境",
            P_VENV,
            on_event,
        )?;
    }
    check_cancel()?;

    // --- step 3: install pdf2zh-next --------------------------------------
    if !venv_babeldoc().exists() {
        emit(
            on_event,
            "安装依赖",
            P_PIP,
            format!("uv pip install pdf2zh-next=={PDF2ZH_NEXT_VERSION}（约 500MB，耗时较长）"),
        );
        let spec = format!("pdf2zh-next=={PDF2ZH_NEXT_VERSION}");
        run_child(
            &uv_binary(),
            &["pip", "install", "--python"],
            &[venv_python().to_string_lossy().as_ref(), &spec],
            &[],
            None,
            "安装依赖",
            P_PIP,
            on_event,
        )?;
    }
    check_cancel()?;

    // --- step 4: model / font assets --------------------------------------
    emit(
        on_event,
        "下载模型资产",
        P_WARMUP,
        "babeldoc --warmup（字体/排版模型/CMap，约 400MB）…",
    );
    run_child(
        &venv_babeldoc(),
        &["--warmup"],
        &[],
        // Air-gapped / mirrored setups can point these at a reachable mirror.
        &asset_env(),
        None,
        "下载模型资产",
        P_WARMUP,
        on_event,
    )?;
    check_cancel()?;

    // --- step 5: manifest --------------------------------------------------
    let manifest = EngineManifest {
        pdf2zh_next: PDF2ZH_NEXT_VERSION.to_string(),
        installed_at: chrono_now(),
        cache_preexisting: CACHE_PREEXISTING.load(Ordering::SeqCst),
    };
    std::fs::write(
        manifest_path(),
        serde_json::to_string_pretty(&manifest)?,
    )?;
    emit(on_event, "完成", 1.0, "翻译引擎安装完成");
    on_event(EngineInstallEvent {
        phase: "完成".into(),
        progress: 1.0,
        detail: String::new(),
        finished: true,
        error: None,
    });
    Ok(())
}

/// Environment overrides passed through to BabelDOC's asset downloader
/// (e.g. `HF_ENDPOINT` for a HuggingFace mirror on networks where
/// huggingface.co is unreachable).
fn asset_env() -> Vec<(String, String)> {
    const PASSTHROUGH: [&str; 3] = ["HF_ENDPOINT", "HF_HOME", "BABELDOC_ASSETS_MIRROR"];
    PASSTHROUGH
        .iter()
        .filter_map(|k| std::env::var(k).ok().map(|v| (k.to_string(), v)))
        .collect()
}

fn run_mock(
    script: &str,
    on_event: &mut impl FnMut(EngineInstallEvent),
) -> AppResult<()> {
    emit(on_event, "模拟安装", 0.1, format!("运行模拟脚本 {script}"));
    let status = Command::new(script)
        .env("RBWA_BABELDOC_DIR", engine_dir())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;
    if !status.success() {
        let e = AppError::Internal(format!("模拟安装脚本退出码 {status}"));
        on_event(EngineInstallEvent {
            phase: "失败".into(),
            progress: 0.0,
            detail: e.to_string(),
            finished: true,
            error: Some(e.to_string()),
        });
        return Err(e);
    }
    emit(on_event, "完成", 1.0, "模拟安装完成");
    on_event(EngineInstallEvent {
        phase: "完成".into(),
        progress: 1.0,
        detail: String::new(),
        finished: true,
        error: None,
    });
    Ok(())
}

fn check_cancel() -> AppResult<()> {
    if CANCEL.load(Ordering::SeqCst) {
        CANCEL.store(false, Ordering::SeqCst);
        return Err(AppError::Internal("安装已取消".into()));
    }
    Ok(())
}

/// Runs a child process, forwarding its latest output lines as detail
/// events and polling so cancellation can kill it.
#[allow(clippy::too_many_arguments)] // low-level runner: command + env + phase label
fn run_child(
    program: &Path,
    args: &[&str],
    extra_args: &[&str],
    env_extra: &[(String, String)],
    cwd: Option<&Path>,
    phase: &str,
    progress: f64,
    on_event: &mut impl FnMut(EngineInstallEvent),
) -> AppResult<()> {
    let mut cmd = Command::new(program);
    cmd.args(args).args(extra_args);
    for (k, v) in env_extra {
        cmd.env(k, v);
    }
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| AppError::Internal(format!("无法启动 {}: {e}", program.display())))?;

    // Reader threads forward lines; the poll loop below re-emits them.
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    if let Some(out) = child.stdout.take() {
        spawn_line_reader(out, tx.clone());
    }
    if let Some(err) = child.stderr.take() {
        spawn_line_reader(err, tx.clone());
    }
    drop(tx);

    let mut tail: Vec<String> = Vec::new();
    let forward = |rx: &std::sync::mpsc::Receiver<String>,
                       tail: &mut Vec<String>,
                       on_event: &mut dyn FnMut(EngineInstallEvent)| {
        while let Ok(line) = rx.try_recv() {
            let line = line.trim().to_string();
            if line.is_empty() {
                continue;
            }
            tail.push(line.clone());
            if tail.len() > 4 {
                tail.remove(0);
            }
            on_event(EngineInstallEvent {
                phase: phase.to_string(),
                progress,
                detail: line,
                finished: false,
                error: None,
            });
        }
    };

    loop {
        forward(&rx, &mut tail, on_event);
        if CANCEL.load(Ordering::SeqCst) {
            let _ = child.kill();
            let _ = child.wait();
            CANCEL.store(false, Ordering::SeqCst);
            return Err(AppError::Internal("安装已取消".into()));
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                // Drain whatever arrived with the exit.
                forward(&rx, &mut tail, on_event);
                if !status.success() {
                    return Err(AppError::Internal(format!(
                        "{} 退出码 {status}：{}",
                        program.display(),
                        tail.join(" | ")
                    )));
                }
                return Ok(());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(e) => return Err(AppError::Internal(format!("等待子进程失败: {e}"))),
        }
    }
}

/// Reads [pipe] line by line on a thread, forwarding each line to [tx].
fn spawn_line_reader(pipe: impl Read + Send + 'static, tx: std::sync::mpsc::Sender<String>) {
    std::thread::spawn(move || {
        use std::io::BufRead;
        let reader = std::io::BufReader::new(pipe);
        for line in reader.lines() {
            match line {
                Ok(l) => {
                    if tx.send(l).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
}

fn chrono_now() -> String {
    // Minimal RFC-3339-ish stamp without a chrono dependency.
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{}", now.as_secs())
}

/// Downloads the pinned uv tarball into `bin/uv`, verifying SHA-256.
fn download_uv(mut on_progress: impl FnMut(f64, u64, u64)) -> AppResult<()> {
    let bin_dir = engine_dir().join("bin");
    std::fs::create_dir_all(&bin_dir)?;
    let url = uv_asset_url();

    // Expected hash (sidecar published next to the artifact).
    let expected = fetch_text(&format!("{url}.sha256"))?
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string();

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(600))
        .build()
        .map_err(|e| AppError::Internal(format!("HTTP 客户端初始化失败: {e}")))?;
    let resp = client
        .get(&url)
        .send()
        .map_err(|e| AppError::Internal(format!("下载 uv 失败: {e}")))?;
    if !resp.status().is_success() {
        return Err(AppError::Internal(format!("下载 uv 失败: HTTP {}", resp.status())));
    }
    let total = resp.content_length().unwrap_or(0);
    let mut buf: Vec<u8> = Vec::with_capacity(total as usize);
    let mut hasher = Sha256::new();
    let mut reader = resp;
    let mut chunk = [0u8; 64 * 1024];
    let mut done: u64 = 0;
    while !CANCEL.load(Ordering::SeqCst) {
        let n = reader
            .read(&mut chunk)
            .map_err(|e| AppError::Internal(format!("下载中断: {e}")))?;
        if n == 0 {
            break;
        }
        hasher.update(&chunk[..n]);
        buf.extend_from_slice(&chunk[..n]);
        done += n as u64;
        on_progress(
            if total > 0 { done as f64 / total as f64 } else { 0.0 },
            done,
            total,
        );
    }
    check_cancel()?;

    let got = format!("{:x}", hasher.finalize());
    if !expected.is_empty() && got != expected {
        return Err(AppError::Internal(format!(
            "uv 校验失败：期望 {expected}，实际 {got}"
        )));
    }

    // Unpack `uv-x86_64-unknown-linux-gnu/uv` from the tarball.
    let gz = flate2::read::GzDecoder::new(std::io::Cursor::new(buf));
    let mut archive = tar::Archive::new(gz);
    for entry in archive.entries()? {
        let mut entry = entry?;
        let path = entry.path()?.to_path_buf();
        if path.file_name().map(|n| n == "uv").unwrap_or(false) {
            let dest = uv_binary();
            if dest.exists() {
                std::fs::remove_file(&dest)?;
            }
            entry.unpack(&dest)?;
            set_executable(&dest)?;
            return Ok(());
        }
    }
    Err(AppError::Internal("uv 压缩包中未找到 uv 可执行文件".into()))
}

fn fetch_text(url: &str) -> AppResult<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .build()
        .map_err(|e| AppError::Internal(format!("HTTP 客户端初始化失败: {e}")))?;
    let text = client
        .get(url)
        .send()
        .map_err(|e| AppError::Internal(format!("获取 {url} 失败: {e}")))?
        .error_for_status()
        .map_err(|e| AppError::Internal(format!("获取 {url} 失败: {e}")))?
        .text()
        .map_err(|e| AppError::Internal(format!("读取 {url} 失败: {e}")))?;
    Ok(text)
}

#[cfg(unix)]
fn set_executable(path: &Path) -> AppResult<()> {
    use std::os::unix::fs::PermissionsExt;
    let mut perm = std::fs::metadata(path)?.permissions();
    perm.set_mode(0o755);
    std::fs::set_permissions(path, perm)?;
    Ok(())
}

#[cfg(not(unix))]
fn set_executable(_path: &Path) -> AppResult<()> {
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;

    // One merged test: the dir overrides are process-global OnceLocks and the
    // scratch state is shared, so parallel test fns would race (the same
    // reason the DB integration tests are single functions).
    #[test]
    fn engine_paths_manifest_and_uninstall() {
        let base = std::env::temp_dir().join(format!("rbwa_engine_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let _ = ENGINE_DIR_OVERRIDE.set(base.join("engine"));
        let _ = CACHE_DIR_OVERRIDE.set(base.join("cache"));

        let dir = engine_dir();
        assert!(dir.ends_with("engine"), "{dir:?}");
        assert_eq!(manifest_path(), dir.join("engine.json"));
        assert_eq!(uv_binary(), dir.join("bin").join("uv"));
        assert_eq!(venv_python(), dir.join("venv").join("bin").join("python"));
        assert!(babeldoc_cache_dir().ends_with("cache"));

        // Fresh scratch dir: not installed.
        assert_eq!(get_engine_status().kind, EngineStatusKind::NotInstalled);

        // Manifest on disk is the authority for "installed".
        std::fs::create_dir_all(&dir).unwrap();
        let m = EngineManifest {
            pdf2zh_next: PDF2ZH_NEXT_VERSION.into(),
            installed_at: "0".into(),
            cache_preexisting: false,
        };
        std::fs::write(manifest_path(), serde_json::to_string(&m).unwrap()).unwrap();
        let s = get_engine_status();
        assert_eq!(s.kind, EngineStatusKind::Installed);
        assert_eq!(s.version, PDF2ZH_NEXT_VERSION);
        assert_eq!(read_manifest().unwrap().pdf2zh_next, PDF2ZH_NEXT_VERSION);

        // Our own install (cache did not pre-exist): both dirs go.
        let cache = babeldoc_cache_dir();
        std::fs::create_dir_all(&cache).unwrap();
        std::fs::write(cache.join("probe.bin"), b"x").unwrap();
        uninstall_engine().unwrap();
        assert!(!dir.exists(), "managed environment must be removed");
        assert!(!cache.exists(), "cache we created must be removed");
        assert_eq!(get_engine_status().kind, EngineStatusKind::NotInstalled);

        // A pre-existing cache (user's own pdf2zh) survives uninstall.
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        let m = EngineManifest {
            pdf2zh_next: PDF2ZH_NEXT_VERSION.into(),
            installed_at: "0".into(),
            cache_preexisting: true,
        };
        std::fs::write(manifest_path(), serde_json::to_string(&m).unwrap()).unwrap();
        uninstall_engine().unwrap();
        assert!(!dir.exists());
        assert!(cache.exists(), "a pre-existing asset cache must be kept");

        let _ = std::fs::remove_dir_all(&base);
    }
}
