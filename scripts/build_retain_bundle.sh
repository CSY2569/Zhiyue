#!/usr/bin/env bash
# Build the RetainPDF-engine AppImage for 智阅 (ZhiYue).
#
# Produces dist/ZhiYue-<ver>-retainpdf-x86_64.AppImage: the normal release
# bundle PLUS the assembled RetainPDF engine under `retainpdf/` (standalone
# CPython + site-packages + Typst + typst-packages + fonts), so translation
# works out of the box with no download. Runtime resolution: `<exe_dir>/
# retainpdf/engine.json` makes the app report the engine as 已内置 (see
# translate::engine).
#
# Requirements:
#   - an assembled engine directory (RBWA_RETAIN_ENGINE_SRC, default
#     <repo>/engine-dev/retainpdf) -- build it with scripts/build_retain_engine.sh
#   - appimagetool + type2-runtime in .packaging-tools (as build_packages.sh)
#
# Notes:
#   - The engine layout is position independent by construction: the pipeline
#     runs as `python -c ...main()` with PYTHONPATH=site-packages and its
#     env vars are set by the Rust side at spawn time (translate::engine), so
#     nothing embeds absolute paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
DIST="$PROJECT_ROOT/dist"
TOOLS="$PROJECT_ROOT/.packaging-tools"
VERSION="${1:-1.0.0}"

ENGINE_SRC="${RBWA_RETAIN_ENGINE_SRC:-$PROJECT_ROOT/engine-dev/retainpdf}"
if [ ! -f "$ENGINE_SRC/engine.json" ]; then
  echo "no assembled engine found at $ENGINE_SRC (run scripts/build_retain_engine.sh)" >&2
  exit 1
fi
echo "==> engine source: $ENGINE_SRC"

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
echo "==> staging bundled engine at $BUNDLE/retainpdf"
ENGINE_DST="$BUNDLE/retainpdf"
rm -rf "$ENGINE_DST"
mkdir -p "$ENGINE_DST"
cp -a "$ENGINE_SRC/." "$ENGINE_DST/"
# Drop build leftovers that are not part of the runtime layout.
rm -rf "$ENGINE_DST/.pyroot" "$ENGINE_DST/.wheels"

# Mark as bundled (the app shows 已内置 and refuses uninstall).
python3 - <<PY
import json, pathlib
p = pathlib.Path("$ENGINE_DST/engine.json")
m = json.loads(p.read_text())
m["bundled"] = True
# size_bytes is recorded pre-copy; refresh it for the staged tree so the app
# never walks the bundle to report the footprint.
import subprocess as _sp
m["size_bytes"] = int(
    _sp.run(["du", "-sb", str(p.parent)], capture_output=True, text=True)
    .stdout.split()[0]
)
p.write_text(json.dumps(m, indent=1, ensure_ascii=False) + "\n")
print("    manifest:", m)
PY
echo "==> bundled engine size: $(du -sh "$ENGINE_DST" | cut -f1)"

# Self-check: the staged engine must run from its final path.
echo "==> verifying the staged engine runs"
PYTHONPATH="$ENGINE_DST/site-packages" TYPST_BIN="$ENGINE_DST/bin/typst" \
  "$ENGINE_DST/python/bin/python3.11" -c \
  "import sys; from retainpdf_pipeline.entrypoints.console import main; sys.argv=['retainpdf-pipeline','--help']; main()" \
  | head -3

# ---------------------------------------------------------------------------
# OCR models (scanned books): bundle them so scanned-page translation works
# offline. Source: RBWA_OCR_MODELS_SRC, else the dev app-data install, else
# scripts/download_ocr_models.sh must be run first.
MODELS_SRC="${RBWA_OCR_MODELS_SRC:-$HOME/.local/share/RBWA/models}"
if [ -d "$BUNDLE/models" ]; then
  echo "==> OCR models already in bundle: $(du -sh "$BUNDLE/models" | cut -f1)"
elif [ -d "$MODELS_SRC" ]; then
  echo "==> copying OCR models from $MODELS_SRC"
  cp -a "$MODELS_SRC" "$BUNDLE/models"
  echo "    models: $(du -sh "$BUNDLE/models" | cut -f1)"
else
  echo "!! no OCR models found (scanned-book translation/OCR will ask for them);" >&2
  echo "   run scripts/download_ocr_models.sh --all --dir <bundle>/models or set RBWA_OCR_MODELS_SRC" >&2
fi

# ---------------------------------------------------------------------------
echo "==> AppImage (with engine)"
mkdir -p "$DIST"
APPDIR="$PROJECT_ROOT/.packaging/AppDir-with-engine"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp -r "$BUNDLE/ZhiYue" "$BUNDLE/lib" "$BUNDLE/data" "$APPDIR/"
[ -d "$BUNDLE/models" ] && cp -r "$BUNDLE/models" "$APPDIR/"
cp -r "$ENGINE_DST" "$APPDIR/retainpdf"
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

OUT="$DIST/ZhiYue-${VERSION}-retainpdf-x86_64.AppImage"
# A running instance keeps the old file open (ETXTBSY): appimagetool then
# fails silently -- unlink first (the running process keeps its inode).
rm -f "$OUT"
"$APPIMAGE_TOOL" --runtime-file "$RUNTIME_FILE" "$APPDIR" "$OUT" >/dev/null 2>&1 || true
if [ ! -f "$OUT" ]; then
  echo "appimagetool failed; rerunning with output for diagnosis" >&2
  "$APPIMAGE_TOOL" --runtime-file "$RUNTIME_FILE" "$APPDIR" "$OUT"
  exit 1
fi
echo
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"