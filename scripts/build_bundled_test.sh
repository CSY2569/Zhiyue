#!/usr/bin/env bash
# Build the "engine bundled" TEST AppImage for 智阅 (ZhiYue).
#
# Produces dist/ZhiYue-<ver>-with-engine-x86_64.AppImage: the normal release
# bundle PLUS a ready-to-run BabelDOC engine under `babeldoc/` (standalone
# CPython + site-packages + BabelDOC's offline asset package), so no ~1.5GB
# download is needed. Runtime resolution: `<exe_dir>/babeldoc/engine.json`
# makes the app report the engine as 已内置 (see translate::engine).
#
# Requirements:
#   - a working engine install to copy from (RBWA_ENGINE_SRC, default
#     ~/.local/share/RBWA/babeldoc, falling back to /tmp/rbwa_engine_real2)
#   - the uv binary that installed it (RBWA_UV_BIN or
#     $RBWA_ENGINE_SRC/bin/uv) for the pristine rebuild below
#   - appimagetool + type2-runtime in .packaging-tools (as build_packages.sh)
#
# Notes:
#   - The venv is REBUILT at the bundle path with uv (console-script
#     shebangs embed their creation path) and BabelDOC runs through
#     `python -c ...main()` with PYTHONPATH, so no venv symlink is relied on.
#   - The bundled CPython is a uv-managed standalone build (relocatable).
#   - Assets: an offline-assets zip is generated and restored on first use.
#     Skipped when the local cache already has them (RBWA_SKIP_ASSETS_ZIP=1
#     for a machine-local build).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
DIST="$PROJECT_ROOT/dist"
TOOLS="$PROJECT_ROOT/.packaging-tools"
VERSION="${1:-1.0.0}"

ENGINE_SRC="${RBWA_ENGINE_SRC:-$HOME/.local/share/RBWA/babeldoc}"
if [ ! -f "$ENGINE_SRC/engine.json" ]; then
  for alt in /tmp/rbwa_engine_real2 /tmp/rbwa_engine_real; do
    if [ -f "$alt/engine.json" ]; then ENGINE_SRC="$alt"; break; fi
  done
fi
if [ ! -f "$ENGINE_SRC/engine.json" ]; then
  echo "no installed engine found (set RBWA_ENGINE_SRC to one with engine.json)" >&2
  exit 1
fi
echo "==> engine source: $ENGINE_SRC"

UV_BIN="${RBWA_UV_BIN:-$ENGINE_SRC/bin/uv}"
[ -x "$UV_BIN" ] || { echo "uv binary not found at $UV_BIN" >&2; exit 1; }

# uv names the dir via a symlink (cpython-3.12-linux-x86_64-gnu ->
# cpython-3.12.13-...): resolve it, or `cp -a` would copy a 4KB symlink.
PY_SRC="$(readlink -f "$(ls -d "$HOME"/.local/share/uv/python/cpython-3.12-* 2>/dev/null | head -1)")"
[ -n "$PY_SRC" ] && [ -x "$PY_SRC/bin/python3.12" ] || {
  echo "no uv-managed CPython 3.12 found" >&2; exit 1; }

APPIMAGE_TOOL="$TOOLS/appimagetool"
RUNTIME_FILE="$TOOLS/runtime-x86_64"
if [ ! -x "$APPIMAGE_TOOL" ] || [ ! -f "$RUNTIME_FILE" ]; then
  echo "appimagetool/type2-runtime missing in $TOOLS -- run scripts/build_packages.sh once" >&2
  exit 1
fi

echo "==> Flutter release bundle"
(cd "$PROJECT_ROOT" && flutter build linux --release)

# ---------------------------------------------------------------------------
# Assemble the engine inside the bundle
echo "==> staging bundled engine at $BUNDLE/babeldoc"
ENGINE_DST="$BUNDLE/babeldoc"
rm -rf "$ENGINE_DST"
mkdir -p "$ENGINE_DST"

# 1. standalone CPython (relocatable by design)
cp -aL "$PY_SRC" "$ENGINE_DST/python"
echo "    python: $(du -sh "$ENGINE_DST/python" | cut -f1)"

# 2. uv binary (used here to build the bundle-local venv; also keeps a future
#    "repair install" possible)
mkdir -p "$ENGINE_DST/bin"
cp -a "$UV_BIN" "$ENGINE_DST/bin/uv"

# 3. build the venv AT ITS FINAL PATH from the warm uv cache (offline):
#    a copied venv would keep stale shebangs and symlinks.
echo "==> building bundle venv (offline, from uv cache)"
INDEX="${RBWA_ENGINE_PYPI_INDEX:-https://pypi.tuna.tsinghua.edu.cn/simple}"
"$ENGINE_DST/bin/uv" venv --python "$ENGINE_DST/python/bin/python3.12" \
  "$ENGINE_DST/venv" >/dev/null
"$ENGINE_DST/bin/uv" pip install --offline --index "$INDEX" \
  --python "$ENGINE_DST/venv/bin/python" "pdf2zh-next==2.9.0" 2>&1 | tail -2

# 4. site-packages straight out of the fresh venv (the runtime uses
#    `python -c ... main()` + PYTHONPATH, avoiding venv paths entirely); the
#    venv itself is then dropped -- it duplicates ~1GB and nothing at runtime
#    depends on it.
cp -a "$ENGINE_DST/venv/lib/python3.12/site-packages" "$ENGINE_DST/site-packages"
rm -rf "$ENGINE_DST/venv"
echo "    site-packages: $(du -sh "$ENGINE_DST/site-packages" | cut -f1)"

# 5. offline asset package (skip for machine-local builds: the cache already
#    has them; unset RBWA_SKIP_ASSETS_ZIP for a portable artifact)
if [ "${RBWA_SKIP_ASSETS_ZIP:-0}" = "1" ]; then
  echo "    assets zip: skipped (RBWA_SKIP_ASSETS_ZIP=1; local cache is used)"
else
  echo "==> generating offline asset package (~330MB)"
  PYTHONPATH="$ENGINE_DST/site-packages" "$ENGINE_DST/python/bin/python3.12" \
    -c "import sys; from babeldoc.main import cli; sys.exit(cli())" \
    --generate-offline-assets "$ENGINE_DST" 2>&1 | tail -2
  ls "$ENGINE_DST"/offline_assets_*.zip >/dev/null
  echo "    assets zip: $(du -sh "$ENGINE_DST"/offline_assets_*.zip | cut -f1)"
fi

# 6. manifest marking the engine as bundled
cat > "$ENGINE_DST/engine.json" <<JSON
{
  "pdf2zh_next": "2.9.0",
  "installed_at": "$(date +%s)",
  "cache_preexisting": true,
  "uv_wheel": null,
  "bundled": true
}
JSON
echo "==> bundled engine size: $(du -sh "$ENGINE_DST" | cut -f1)"

# 7. self-check: the staged engine must actually RUN from its final path
#    (python + PYTHONPATH, no venv involved).
echo "==> verifying the staged engine runs"
PYTHONPATH="$ENGINE_DST/site-packages" "$ENGINE_DST/python/bin/python3.12" \
  -c "import sys; from babeldoc.main import cli; sys.exit(cli())" --version

# ---------------------------------------------------------------------------
echo "==> AppImage (with engine)"
# Mirrors build_packages.sh: a FLAT AppDir (ZhiYue/lib/data/models at the
# root) -- the engine rides along as `babeldoc/`, which is exactly where
# translate::engine looks for a bundled engine (exe_dir/babeldoc).
APPDIR="$PROJECT_ROOT/.packaging/AppDir-with-engine"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp -r "$BUNDLE/ZhiYue" "$BUNDLE/lib" "$BUNDLE/data" "$APPDIR/"
[ -d "$BUNDLE/models" ] && cp -r "$BUNDLE/models" "$APPDIR/"
cp -r "$ENGINE_DST" "$APPDIR/babeldoc"
cp "$PROJECT_ROOT/packaging/ZhiYue.desktop" "$APPDIR/"
cp "$PROJECT_ROOT/packaging/icon/zhiyue.png" "$APPDIR/"
cp "$PROJECT_ROOT/LICENSE" "$APPDIR/"
cat > "$APPDIR/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/ZhiYue" "$@"
RUN
chmod +x "$APPDIR/AppRun"

OUT="$DIST/ZhiYue-${VERSION}-with-engine-x86_64.AppImage"
"$APPIMAGE_TOOL" --runtime-file "$RUNTIME_FILE" "$APPDIR" "$OUT" >/dev/null 2>&1
echo
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
