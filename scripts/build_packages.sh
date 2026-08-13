#!/usr/bin/env bash
# Build all Linux distribution packages for 智阅 (ZhiYue):
#   - dist/zhiyue_<ver>_amd64.deb    (Debian / Ubuntu)
#   - dist/ZhiYue-<ver>-1.x86_64.rpm (Fedora / RHEL / OpenSUSE)
#   - dist/ZhiYue-x86_64.AppImage     (any distro, no install needed)
#
# Requirements:
#   - flutter build linux --release works on this machine
#   - ar (binutils) for the .deb
#   - rpmbuild for the .rpm
#   - appimagetool + type2-runtime for the AppImage (downloaded on demand)
#
# Usage: bash scripts/build_packages.sh [version]

set -euo pipefail

VERSION="${1:-0.1.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
DIST="$PROJECT_ROOT/dist"
TOOLS="$PROJECT_ROOT/.packaging-tools"

mkdir -p "$DIST" "$TOOLS"

echo "==> Building Flutter Linux release bundle"
(cd "$PROJECT_ROOT" && flutter build linux --release)

if [ ! -x "$BUNDLE/ZhiYue" ]; then
  echo "bundle missing: $BUNDLE/ZhiYue" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
echo "==> OCR models (shipped inside the packages, both modes)"
if [ -f "$BUNDLE/models/fast/det.onnx" ] && [ -f "$BUNDLE/models/high_precision/det.onnx" ]; then
  echo "    models already present in bundle (fast + high_precision)"
else
  bash "$SCRIPT_DIR/download_ocr_models.sh" --all --dir "$BUNDLE/models"
fi
du -sh "$BUNDLE/models"

# ---------------------------------------------------------------------------
echo "==> .deb (ar-based, no dpkg toolchain needed)"
bash "$SCRIPT_DIR/build_deb.sh" "$VERSION"

# ---------------------------------------------------------------------------
echo "==> .rpm (rpmbuild)"
RPMBUILD_DIR="${RPMBUILD_DIR:-$HOME/rpmbuild}"
mkdir -p "$RPMBUILD_DIR"/{SOURCES,BUILD,RPMS}
# Fresh copy each run: a stale SOURCES/bundle (e.g. from a previous binary
# name) would otherwise linger or nest (cp -r into an existing dir creates
# SOURCES/bundle/bundle) and break %{_sourcedir}/bundle lookups.
rm -rf "$RPMBUILD_DIR/SOURCES/bundle"
cp -r "$BUNDLE" "$RPMBUILD_DIR/SOURCES/bundle"
cp -r "$PROJECT_ROOT/packaging" "$RPMBUILD_DIR/SOURCES/"
rpmbuild -bb "$RPMBUILD_DIR/SOURCES/packaging/ZhiYue.spec" >/dev/null
cp "$RPMBUILD_DIR"/RPMS/x86_64/ZhiYue-*.x86_64.rpm "$DIST/"

# ---------------------------------------------------------------------------
echo "==> AppImage (appimagetool)"
APPIMAGETOOL="$TOOLS/appimagetool"
RUNTIME="$TOOLS/runtime-x86_64"
if [ ! -x "$APPIMAGETOOL" ]; then
  echo "    downloading appimagetool ..."
  curl -sSL --retry 3 -o "$APPIMAGETOOL" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage" \
    || { echo "ERROR: failed to download appimagetool" >&2; exit 1; }
  chmod +x "$APPIMAGETOOL"
fi
# appimagetool's embedded downloader cannot follow GitHub's redirect
# ("server returned status code 0"), so the type2 runtime must be fetched
# separately with curl and passed via --runtime-file.
if [ ! -f "$RUNTIME" ]; then
  echo "    downloading type2-runtime ..."
  curl -sSL --retry 3 -o "$RUNTIME" \
    "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64" \
    || { echo "ERROR: failed to download type2-runtime (needed by appimagetool)" >&2; exit 1; }
fi

APPDIR="$PROJECT_ROOT/.packaging/AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
cp -r "$BUNDLE/ZhiYue" "$BUNDLE/lib" "$BUNDLE/data" "$BUNDLE/models" "$APPDIR/"
cp "$PROJECT_ROOT/packaging/ZhiYue.desktop" "$APPDIR/"
cp "$PROJECT_ROOT/packaging/icon/zhiyue.png" "$APPDIR/"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
exec "$HERE/ZhiYue" "$@"
EOF
chmod +x "$APPDIR/AppRun"

"$APPIMAGETOOL" --runtime-file "$RUNTIME" "$APPDIR" "$DIST/ZhiYue-x86_64.AppImage" >/dev/null

echo
echo "==> Done. Artifacts in $DIST:"
for f in "$DIST"/*; do
  [ -f "$f" ] && echo "  $(du -h "$f" | cut -f1)  $(basename "$f")"
done
