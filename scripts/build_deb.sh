#!/usr/bin/env bash
# Build a Debian .deb package for RBWA (x86_64).
#
# The .deb is assembled manually with `ar` (debian-binary + control.tar.gz +
# data.tar.gz), so no dpkg toolchain is required on the build machine.
#
# Layout (RPATH $ORIGIN/lib resolves against the real exe path, so a /usr/bin
# symlink to usr/lib/zhiyue/ZhiYue keeps the libraries findable):
#   usr/bin/ZhiYue                       -> ../lib/zhiyue/ZhiYue (symlink)
#   usr/lib/zhiyue/ZhiYue                  (executable)
#   usr/lib/zhiyue/lib/*.so              (flutter engine, rbwa_core, pdfium...)
#   usr/lib/zhiyue/data/                 (flutter_assets + icudtl.dat)
#   usr/share/applications/ZhiYue.desktop
#   usr/share/icons/hicolor/512x512/apps/zhiyue.png
#   usr/share/doc/zhiyue/copyright            (GPL-3.0 license text)
#
# Usage: bash scripts/build_deb.sh [version]

set -euo pipefail

VERSION="${1:-0.1.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLE="$PROJECT_ROOT/build/linux/x64/release/bundle"
OUT_DIR="$PROJECT_ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$BUNDLE/ZhiYue" ]; then
  echo "release bundle not found at $BUNDLE -- run 'flutter build linux --release' first" >&2
  exit 1
fi

# --- data.tar.gz: the actual files -----------------------------------------
DATA="$WORK/data"
mkdir -p "$DATA/usr/bin" \
         "$DATA/usr/lib/zhiyue/lib" \
         "$DATA/usr/share/applications" \
         "$DATA/usr/share/icons/hicolor/512x512/apps" \
         "$DATA/usr/share/doc/zhiyue"

cp "$BUNDLE/ZhiYue" "$DATA/usr/lib/zhiyue/ZhiYue"
cp "$BUNDLE"/lib/*.so "$DATA/usr/lib/zhiyue/lib/"
cp -r "$BUNDLE/data" "$DATA/usr/lib/zhiyue/data"
# OCR models ship next to the executable (Rust resolves <exe dir>/models).
cp -r "$BUNDLE/models" "$DATA/usr/lib/zhiyue/models"
ln -s ../lib/zhiyue/ZhiYue "$DATA/usr/bin/ZhiYue"
cp "$PROJECT_ROOT/packaging/ZhiYue.desktop" "$DATA/usr/share/applications/"
cp "$PROJECT_ROOT/packaging/icon/zhiyue.png" \
   "$DATA/usr/share/icons/hicolor/512x512/apps/zhiyue.png"
# License text (Debian convention: copyright file under share/doc).
cp "$PROJECT_ROOT/LICENSE" "$DATA/usr/share/doc/zhiyue/copyright"

# normalize owner/perms
find "$DATA" -type f -exec chmod 644 {} \;
chmod 755 "$DATA/usr/lib/zhiyue/ZhiYue" "$DATA/usr/bin/ZhiYue"
# flutter_assets must stay readable; keep dirs traversable
find "$DATA" -type d -exec chmod 755 {} \;
# symlink stays a symlink
rm -f "$DATA/usr/bin/ZhiYue" && ln -s ../lib/zhiyue/ZhiYue "$DATA/usr/bin/ZhiYue"

tar -C "$DATA" -czf "$WORK/data.tar.gz" usr

# --- control.tar.gz: package metadata --------------------------------------
CTRL="$WORK/ctrl"
mkdir -p "$CTRL"
SIZE="$(du -sk "$DATA" | cut -f1)"
cat > "$CTRL/control" <<EOF
Package: zhiyue
Version: $VERSION
Section: office
Priority: optional
Architecture: amd64
Depends: libgtk-3-0 (>= 3.22), libglib2.0-0 (>= 2.50), libc6 (>= 2.31), libstdc++6 (>= 9), libfontconfig1 (>= 2.12), libx11-6, libpango-1.0-0 (>= 1.40), libcairo2 (>= 1.14), libxkbcommon0 (>= 0.8), libharfbuzz0b (>= 2.0), libfreetype6 (>= 2.8), libpng16-16, libicu70 | libicu72 | libicu74 | libicu76, libsqlite3-0 (>= 3.30), libxml2 (>= 2.9), libdbus-1-3 (>= 1.12), fonts-noto-cjk
Maintainer: ZhiYue <zhiyue@localhost>
Description: 智阅 - AI-powered local PDF/image reader
  Local PDF/image reader with AI integration: text selection, annotations,
  full-page OCR (PP-OCRv4, fully offline), full-text search and AI chat /
  translate / explain (BYOK, OpenAI-compatible).
  .
  OCR models (both modes) are bundled with the package.
Installed-Size: $SIZE
EOF
tar -C "$CTRL" -czf "$WORK/control.tar.gz" control
printf '2.0\n' > "$WORK/debian-binary"

# --- assemble the .deb ------------------------------------------------------
mkdir -p "$OUT_DIR"
ar rcs "$OUT_DIR/zhiyue_${VERSION}_amd64.deb" \
  "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.gz"

echo "Built $OUT_DIR/zhiyue_${VERSION}_amd64.deb ($(du -h "$OUT_DIR/zhiyue_${VERSION}_amd64.deb" | cut -f1))"
echo "Install: sudo apt install ./zhiyue_${VERSION}_amd64.deb"
