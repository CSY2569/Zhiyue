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

/// Pinned pdf2zh-next (its BabelDOC dependency is pinned by the package).
/// uv itself is fetched as the newest x86_64 Linux wheel from the PyPI simple
/// index -- it is only a bootstrap tool and mirrors stay in sync.
const PDF2ZH_NEXT_VERSION: &str = "2.9.0";
/// Python the engine environment runs on (BabelDOC requires >=3.10,<3.14).
const PYTHON_VERSION: &str = "3.12";

/// Explicit User-Agent: some mirrors (e.g. pypi.tuna.tsinghua.edu.cn) answer
/// 403 to requests WITHOUT one, and reqwest sends none by default.
const USER_AGENT: &str = concat!("rbwa-core/", env!("CARGO_PKG_VERSION"));

/// Install-phase progress bands (whole-install fraction).
const P_UV_START: f64 = 0.0;
const P_UV_SPAN: f64 = 0.10;
const P_VENV: f64 = 0.12;
const P_PIP: f64 = 0.25;
const P_WARMUP: f64 = 0.60;

/// Test/dry-run override for the engine directory (set once per process,
/// mirroring `db::connection::DATA_DIR_OVERRIDE`) -- the env var below serves
/// manual smoke runs, the OnceLock keeps parallel tests race-free.
static ENGINE_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();
/// Same for BabelDOC's asset cache: tests must never touch the user's real
/// `~/.cache/babeldoc` (uninstall deletes it).
static CACHE_DIR_OVERRIDE: OnceLock<PathBuf> = OnceLock::new();

/// An engine shipped INSIDE the installation bundle (`<exe_dir>/babeldoc`,
/// mirroring the OCR models' resolution): packaged test builds carry the
/// interpreter + site-packages + offline asset package, so no download is
/// needed. Layout: `python/` (standalone CPython), `site-packages/`,
/// `engine.json`, optional `offline_assets_*.zip`.
pub fn bundled_engine_dir() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let dir = exe.parent()?.join("babeldoc");
    dir.join("engine.json").is_file().then_some(dir)
}

/// The managed engine directory: a bundled engine wins; otherwise
/// `{app_data_dir}/babeldoc` (override: `RBWA_BABELDOC_DIR`).
pub fn engine_dir() -> PathBuf {
    if let Some(dir) = ENGINE_DIR_OVERRIDE.get() {
        return dir.clone();
    }
    if let Some(bundled) = bundled_engine_dir() {
        return bundled;
    }
    if let Ok(dir) = std::env::var("RBWA_BABELDOC_DIR") {
        return PathBuf::from(dir);
    }
    crate::db::app_data_dir()
        .unwrap_or_default()
        .join("babeldoc")
}

/// Whether the active engine comes from the installation bundle (not
/// removable by the user).
pub fn is_bundled() -> bool {
    bundled_engine_dir().is_some()
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

/// Interpreter used to run BabelDOC: a bundled engine uses its standalone
/// CPython directly (no venv: absolute symlinks/shebangs would break under
/// the AppImage's per-run mount path, and `PYTHONPATH` supplies the
/// packages); a downloaded engine uses its venv python.
pub fn python_executable() -> PathBuf {
    if is_bundled() {
        let bundled = engine_dir().join("python").join("bin").join("python3.12");
        if bundled.exists() {
            return bundled;
        }
    }
    venv_python()
}

/// Extra environment for running BabelDOC out of [engine_dir].
pub fn python_env() -> Vec<(String, String)> {
    let mut env = Vec::new();
    if is_bundled() {
        env.push((
            "PYTHONPATH".to_string(),
            engine_dir()
                .join("site-packages")
                .to_string_lossy()
                .to_string(),
        ));
    }
    env
}

/// Command-line args that invoke the BabelDOC CLI via the module entry point
/// (`babeldoc` has no `__main__`; console scripts carry absolute shebangs).
/// The entry is `cli()` -- the top-level `main()` is a coroutine and calling
/// it bare silently does nothing (caught by the packaging self-check).
pub fn babeldoc_argv() -> [&'static str; 2] {
    ["-c", "import sys; from babeldoc.main import cli; sys.exit(cli())"]
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
    /// The uv wheel the bootstrap step downloaded (traceability; the version
    /// follows the configured index).
    #[serde(default)]
    pub uv_wheel: Option<String>,
    /// Engine shipped inside the installation bundle (cannot be uninstalled).
    #[serde(default)]
    pub bundled: bool,
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
/// The uv wheel filename this install actually used (manifest traceability).
static UV_WHEEL: OnceLock<String> = OnceLock::new();

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
            bundled: m.bundled || is_bundled(),
        },
        None => EngineStatus {
            kind: EngineStatusKind::NotInstalled,
            phase: String::new(),
            progress: 0.0,
            version: String::new(),
            size_bytes: engine_disk_usage(),
            error: None,
            bundled: false,
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
    if is_bundled() {
        return Err(AppError::Internal(
            "引擎内置于安装包，无法卸载（更换发行版即可移除）".into(),
        ));
    }
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
            bundled: false,
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
    // Dry-run hook: CI / smoke runs replace the download/install steps with
    // a script; the manifest step below always stays ours, so the dry run
    // exercises the same state transitions as a real install.
    if let Ok(script) = std::env::var("RBWA_BABELDOC_MOCK_SCRIPT") {
        run_mock(&script, on_event)?;
    } else {
        run_steps(on_event)?;
    }

    // --- manifest ----------------------------------------------------------
    let manifest = EngineManifest {
        pdf2zh_next: PDF2ZH_NEXT_VERSION.to_string(),
        installed_at: chrono_now(),
        cache_preexisting: CACHE_PREEXISTING.load(Ordering::SeqCst),
        uv_wheel: UV_WHEEL.get().cloned(),
        bundled: false, // the installer always produces a user-space engine
    };
    std::fs::write(manifest_path(), serde_json::to_string_pretty(&manifest)?)?;
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

/// The real download/install steps (1-4). Idempotent: each skips when its
/// output exists.
fn run_steps(on_event: &mut impl FnMut(EngineInstallEvent)) -> AppResult<()> {
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
        let venv_path = venv_dir();
        run_child(
            &uv_binary(),
            &["--no-cache", "venv", "--python", PYTHON_VERSION],
            // Target dir as an ARG (not cwd): spawning with a cwd that does
            // not exist yet fails with ENOENT before uv ever runs.
            &[venv_path.to_string_lossy().as_ref()],
            &[],
            None,
            "创建 Python 环境",
            P_VENV,
            on_event,
        )
        .map_err(|e| {
            with_mirror_hint(
                e,
                "UV_PYTHON_INSTALL_MIRROR",
                "无法直连 GitHub 时设置 UV_PYTHON_INSTALL_MIRROR 指向 python-build-standalone 镜像（已验证可用：https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone/）",
            )
        })?;
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
            &["--no-cache", "pip", "install", "--python"],
            &[venv_python().to_string_lossy().as_ref(), &spec],
            &[],
            None,
            "安装依赖",
            P_PIP,
            on_event,
        )
        .map_err(|e| {
            with_mirror_hint(
                e,
                "UV_DEFAULT_INDEX",
                "下载慢或失败时设置 UV_DEFAULT_INDEX 指向 PyPI 镜像（如 https://pypi.tuna.tsinghua.edu.cn/simple）",
            )
        })?;
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
    Ok(())
}

/// Environment overrides passed through to the child steps: index/mirror
/// settings for uv (PyPI index, CPython download mirror) and BabelDOC's asset
/// downloader (`HF_ENDPOINT` etc. -- its multi-upstream race also picks a
/// reachable source on its own).
fn asset_env() -> Vec<(String, String)> {
    const PASSTHROUGH: [&str; 7] = [
        // BabelDOC asset downloads
        "HF_ENDPOINT",
        "HF_HOME",
        "BABELDOC_ASSETS_MIRROR",
        // uv: package index + managed-CPython source
        "UV_DEFAULT_INDEX",
        "UV_INDEX_URL",
        "UV_PYTHON_INSTALL_MIRROR",
        "PIP_INDEX_URL",
    ];
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
    emit(on_event, "模拟安装", 0.9, "模拟安装完成");
    Ok(())
}

/// Appends a mirror hint to a step failure when the relevant env var is
/// unset (so users on restricted networks get an actionable message).
fn with_mirror_hint(e: AppError, var: &str, hint: &str) -> AppError {
    if std::env::var(var).is_ok() {
        return e;
    }
    AppError::Internal(format!("{e}\n提示：{hint}"))
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
    // Contain uv's own artifacts inside the engine dir: the managed CPython
    // install and any residual cache must die with `uninstall` (and show up
    // in the reported footprint) instead of living in the user's home.
    let engine = engine_dir();
    cmd.env("UV_PYTHON_INSTALL_DIR", engine.join("python"));
    cmd.env("UV_CACHE_DIR", engine.join("uv-cache"));
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

    // uv ships on PyPI; the simple index (PEP 503) is the source, NOT the
    // GitHub release -- release assets live on a separate host that some
    // networks block entirely. Mirrors work by pointing
    // `RBWA_ENGINE_PYPI_INDEX` at e.g. https://pypi.tuna.tsinghua.edu.cn/simple
    let index_url = format!("{}/uv/", pypi_index_base());
    let html = fetch_text(&index_url)
        .map_err(|e| AppError::Internal(format!("获取 uv 索引 {index_url} 失败: {e}")))?;
    let (wheel_url, expected_sha) = find_uv_wheel(&html, &index_url)?;
    let _ = UV_WHEEL.set(
        wheel_url
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .split('#')
            .next()
            .unwrap_or_default()
            .to_string(),
    );

    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(1800))
        .user_agent(USER_AGENT)
        .build()
        .map_err(|e| AppError::Internal(format!("HTTP 客户端初始化失败: {e}")))?;
    let resp = client
        .get(&wheel_url)
        .send()
        .map_err(|e| AppError::Internal(format!("下载 uv 失败: {e}")))?;
    if !resp.status().is_success() {
        return Err(AppError::Internal(format!(
            "下载 uv 失败: HTTP {} ({wheel_url})",
            resp.status()
        )));
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

    if let Some(expected) = expected_sha {
        let got = format!("{:x}", hasher.finalize());
        if got != expected {
            return Err(AppError::Internal(format!(
                "uv 校验失败：期望 {expected}，实际 {got}"
            )));
        }
    }

    // The wheel embeds the binary at `<dist>.data/scripts/uv`.
    let reader = std::io::Cursor::new(buf);
    let mut zip = zip::ZipArchive::new(reader)
        .map_err(|e| AppError::Internal(format!("解析 uv wheel 失败: {e}")))?;
    for i in 0..zip.len() {
        let mut file = zip
            .by_index(i)
            .map_err(|e| AppError::Internal(format!("读取 uv wheel 失败: {e}")))?;
        if !file.name().ends_with("/uv") && file.name() != "uv" {
            continue;
        }
        let dest = uv_binary();
        if dest.exists() {
            std::fs::remove_file(&dest)?;
        }
        let mut out = std::fs::File::create(&dest)?;
        std::io::copy(&mut file, &mut out)?;
        drop(out);
        set_executable(&dest)?;
        return Ok(());
    }
    Err(AppError::Internal("uv wheel 中未找到 uv 可执行文件".into()))
}

/// PyPI simple-index base (`RBWA_ENGINE_PYPI_INDEX`; default pypi.org).
fn pypi_index_base() -> String {
    std::env::var("RBWA_ENGINE_PYPI_INDEX")
        .unwrap_or_else(|_| "https://pypi.org/simple".to_string())
        .trim_end_matches('/')
        .to_string()
}

/// Finds the NEWEST x86_64 Linux uv wheel in a simple-index page (mirrors
/// list versions oldest-first, so picking the first match would install a
/// prehistoric uv). Returns the absolute download URL plus the `#sha256=`
/// fragment when the index provides one (pypi.org does; some mirrors omit
/// it).
fn find_uv_wheel(html: &str, index_url: &str) -> AppResult<(String, Option<String>)> {
    /// (version key, download URL, sha256)
    type Candidate = ((u64, u64, u64), String, Option<String>);
    let mut best: Option<Candidate> = None;
    for href in extract_hrefs(html) {
        let (url_part, frag) = match href.split_once('#') {
            Some((u, f)) => (u, Some(f)),
            None => (href.as_str(), None),
        };
        let name = url_part.rsplit('/').next().unwrap_or_default();
        if !name.ends_with(".whl")
            || !name.contains("x86_64")
            || !name.contains("linux")
            || name.contains("musllinux")
        {
            continue;
        }
        let Some(key) = wheel_version_key(name) else {
            continue;
        };
        if best.as_ref().map(|(k, _, _)| key > *k).unwrap_or(true) {
            let url = resolve_url(index_url, url_part);
            let sha = frag
                .and_then(|f| f.strip_prefix("sha256="))
                .map(str::to_string);
            best = Some((key, url, sha));
        }
    }
    match best {
        Some((_, url, sha)) => Ok((url, sha)),
        None => Err(AppError::Internal(format!(
            "索引 {index_url} 中未找到 x86_64 Linux 的 uv wheel"
        ))),
    }
}

/// Version key of a uv wheel filename (`uv-0.12.16-py3-none-...whl`).
/// Pre-release suffixes (rc/beta) are ignored; fully numeric parts win.
fn wheel_version_key(name: &str) -> Option<(u64, u64, u64)> {
    let rest = name.strip_prefix("uv-")?;
    let version = rest.split_once("-py3")?.0;
    let mut nums = [0u64; 3];
    for (i, part) in version.split('.').enumerate().take(3) {
        let digits: String = part.chars().take_while(|c| c.is_ascii_digit()).collect();
        nums[i] = digits.parse().ok()?;
    }
    Some((nums[0], nums[1], nums[2]))
}

/// Resolves a simple-index href against the index page URL, handling the
/// `../../packages/...` relative form mirrors use and absolute paths.
fn resolve_url(index_url: &str, href: &str) -> String {
    if href.starts_with("http://") || href.starts_with("https://") {
        return href.to_string();
    }
    let scheme_host = index_url
        .split_once("://")
        .and_then(|(scheme, rest)| rest.split_once('/').map(|(host, _)| format!("{scheme}://{host}")))
        .unwrap_or_default();
    if href.starts_with('/') {
        return format!("{scheme_host}{href}");
    }
    // Resolve dot-segments against the index path (`/simple/uv/`).
    let base_path = index_url
        .split_once("://")
        .map(|(_, rest)| rest.split_once('/').map(|(_, p)| format!("/{p}")).unwrap_or_else(|| "/".into()))
        .unwrap_or_else(|| "/".into());
    let mut segments: Vec<&str> = base_path.split('/').filter(|s| !s.is_empty()).collect();
    for part in href.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                segments.pop();
            }
            other => segments.push(other),
        }
    }
    format!("{scheme_host}/{}", segments.join("/"))
}

/// `href="..."` values of a simple-index page (quote style varies).
fn extract_hrefs(html: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(pos) = rest.find("href=") {
        rest = &rest[pos + 5..];
        let quote = rest.chars().next().unwrap_or('"');
        if quote != '"' && quote != '\'' {
            continue;
        }
        let inner = &rest[1..];
        if let Some(end) = inner.find(quote) {
            out.push(inner[..end].to_string());
            rest = &inner[end + 1..];
        } else {
            break;
        }
    }
    out
}

fn fetch_text(url: &str) -> AppResult<String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(60))
        .user_agent(USER_AGENT)
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
/// Restores BabelDOC's asset cache from a bundled offline-assets package when
/// the cache is missing (bundled test builds ship one so no download is
/// needed). Returns the number of restored packages' lines on success; a
/// no-op when no package / cache already present.
pub fn restore_bundled_assets(
    on_line: &mut impl FnMut(String),
) -> AppResult<bool> {
    let Some(bundled) = bundled_engine_dir() else {
        return Ok(false);
    };
    if babeldoc_cache_dir().join("models").is_dir() {
        return Ok(false); // assets already in place
    }
    let zip = std::fs::read_dir(&bundled)
        .ok()
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .map(|n| {
                    let n = n.to_string_lossy();
                    n.starts_with("offline_assets_") && n.ends_with(".zip")
                })
                .unwrap_or(false)
        });
    let Some(zip) = zip else {
        return Ok(false);
    };

    let mut cmd = Command::new(python_executable());
    let argv = babeldoc_argv();
    cmd.args(argv)
        .args(["--restore-offline-assets", &zip.to_string_lossy()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    for (k, v) in python_env() {
        cmd.env(k, v);
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| AppError::Internal(format!("资产恢复失败（无法启动）: {e}")))?;
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    if let Some(out) = child.stdout.take() {
        spawn_line_reader(out, tx.clone());
    }
    if let Some(err) = child.stderr.take() {
        spawn_line_reader(err, tx.clone());
    }
    drop(tx);
    loop {
        while let Ok(line) = rx.try_recv() {
            let line = line.trim().to_string();
            if !line.is_empty() {
                on_line(line);
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    return Err(AppError::Internal(format!(
                        "资产恢复失败：退出码 {status}"
                    )));
                }
                return Ok(true);
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(200)),
            Err(e) => return Err(AppError::Internal(format!("等待资产恢复失败: {e}"))),
        }
    }
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
            uv_wheel: None,
            bundled: false,
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
            uv_wheel: None,
            bundled: false,
        };
        std::fs::write(manifest_path(), serde_json::to_string(&m).unwrap()).unwrap();
        uninstall_engine().unwrap();
        assert!(!dir.exists());
        assert!(cache.exists(), "a pre-existing asset cache must be kept");

        let _ = std::fs::remove_dir_all(&base);
    }

    /// Regression: mirrors list versions oldest-first and use relative
    /// `../../packages/...` hrefs -- the newest wheel must be picked and its
    /// URL resolved to an absolute one (a first-match pick installed uv
    /// 0.0.5, and the join produced `host../packages/...`).
    #[test]
    fn uv_wheel_pick_newest_and_resolve_relative_urls() {
        let html = r#"
<a href="../../packages/aa/uv-0.0.5-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl#sha256=aaa">uv-0.0.5</a>
<a href="../../packages/bb/uv-0.12.16-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl#sha256=bbb">uv-0.12.16</a>
<a href="../../packages/cc/uv-0.12.16-py3-none-musllinux_1_1_x86_64.whl#sha256=ccc">musl</a>
<a href="../../packages/dd/uv-0.12.16-py3-none-manylinux_2_17_aarch64.manylinux2014_aarch64.whl">arm</a>
"#;
        let (url, sha) = find_uv_wheel(html, "https://pypi.tuna.tsinghua.edu.cn/simple/uv/").unwrap();
        assert_eq!(
            url,
            "https://pypi.tuna.tsinghua.edu.cn/packages/bb/uv-0.12.16-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.whl"
        );
        assert_eq!(sha.as_deref(), Some("bbb"));

        // Absolute hrefs pass through; no sha fragment stays None.
        let abs = r#"<a href="https://files.pythonhosted.org/packages/x/uv-1.2.3-py3-none-manylinux1_x86_64.whl">x</a>"#;
        let (url, sha) = find_uv_wheel(abs, "https://pypi.org/simple/uv/").unwrap();
        assert!(url.starts_with("https://files.pythonhosted.org/"));
        assert_eq!(sha, None);

        assert!(find_uv_wheel("<html></html>", "https://pypi.org/simple/uv/").is_err());
    }

    /// REAL install smoke (ignored by default; run with
    /// `cargo test --features pdf,ai engine_real_install -- --ignored --nocapture`).
    /// Downloads ~1GB (uv + CPython + pdf2zh-next + model assets) into
    /// `RBWA_BABELDOC_DIR`; BabelDOC's asset cache goes to its standard
    /// `~/.cache/babeldoc` (its own multi-upstream race picks a reachable
    /// source -- this machine cannot reach huggingface.co).
    #[test]
    #[ignore = "downloads ~1GB; run manually"]
    fn engine_real_install_smoke() {
        let started = std::time::Instant::now();
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let result = install_engine(move |ev| {
                println!(
                    "[{:>6.2}s] {:<14} {:>5.1}%  {}",
                    started.elapsed().as_secs_f64(),
                    ev.phase,
                    ev.progress * 100.0,
                    ev.detail
                );
            })
            .await;
            println!("install result: {result:?}");
            println!("elapsed: {:.1}s", started.elapsed().as_secs_f64());
            let s = get_engine_status();
            println!(
                "status: {:?} version={} size={:.2}GB",
                s.kind,
                s.version,
                s.size_bytes as f64 / 1e9
            );
            assert!(result.is_ok(), "install failed: {result:?}");
            assert_eq!(s.kind, EngineStatusKind::Installed);
        });
    }
}
