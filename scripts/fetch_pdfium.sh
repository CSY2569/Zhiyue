#!/usr/bin/env bash
#
# Fetches the prebuilt pdfium dynamic library (BSD-3) from bblanchon/pdfium-binaries
# and places it at rust/libpdfium/libpdfium.so for the Rust core to link at runtime.
#
# The library is bundled into the Flutter Linux bundle's lib/ dir by CMake
# (see linux/CMakeLists.txt), so the RPATH $ORIGIN/lib lets pdfium-render's
# libloading find it alongside librbwa_core.so.
#
# Idempotent: skips the download if the .so is already present.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST_DIR="$PROJECT_ROOT/rust/libpdfium"
DEST_LIB="$DEST_DIR/libpdfium.so"

# --- helpers ----------------------------------------------------------------
c_red()   { printf '\033[31m%s\033[0m\n' "$*"; }
c_green() { printf '\033[32m%s\033[0m\n' "$*"; }
c_yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
c_blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

info()  { c_blue "▸ $*"; }
ok()    { c_green "✓ $*"; }
warn()  { c_yellow "⚠ $*"; }
err()   { c_red "✗ $*" >&2; }

# --- main -------------------------------------------------------------------

# Only Linux x64 is handled here; other platforms would need their own archive
# (e.g. pdfium-mac-arm64.tgz, pdfium-win-x64.tgz).
ARCH="$(uname -m)"
OS="$(uname -s)"
case "$OS-$ARCH" in
  Linux-x86_64|Linux-aarch64)
    PDFIUM_ARCH="linux-x64"
    [[ "$ARCH" == "aarch64" ]] && PDFIUM_ARCH="linux-arm64"
    ;;
  Darwin-arm64)  PDFIUM_ARCH="mac-arm64" ;;
  Darwin-x86_64) PDFIUM_ARCH="mac-x64" ;;
  *) err "unsupported platform: $OS-$ARCH"; exit 1 ;;
esac

info "target platform: $PDFIUM_ARCH"

if [[ -f "$DEST_LIB" ]] && [[ -s "$DEST_LIB" ]]; then
  ok "pdfium library already present at $DEST_LIB (skipping download)"
  exit 0
fi

mkdir -p "$DEST_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/bblanchon/pdfium-binaries/releases/latest/download/pdfium-${PDFIUM_ARCH}.tgz"
info "downloading $URL ..."

if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 -o "$TMP_DIR/pdfium.tgz" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q --tries=3 -O "$TMP_DIR/pdfium.tgz" "$URL"
else
  err "neither curl nor wget is installed"
  exit 1
fi

ok "download complete"

info "extracting..."
tar -xzf "$TMP_DIR/pdfium.tgz" -C "$TMP_DIR"

# The archive layout: lib/libpdfium.so (Linux) | lib/libpdfium.dylib (macOS)
SRC_LIB=""
for candidate in \
  "$TMP_DIR/lib/libpdfium.so" \
  "$TMP_DIR/lib/libpdfium.dylib" \
  "$TMP_DIR/lib/libpdfium.dll"; do
  if [[ -f "$candidate" ]]; then
    SRC_LIB="$candidate"
    break
  fi
done

if [[ -z "$SRC_LIB" ]]; then
  err "could not find the pdfium shared library in the archive"
  ls -R "$TMP_DIR" >&2
  exit 1
fi

cp "$SRC_LIB" "$DEST_LIB"
chmod 0644 "$DEST_LIB"

SIZE_KB="$(du -k "$DEST_LIB" | cut -f1)"
ok "pdfium library installed: $DEST_LIB (${SIZE_KB} KB)"
info "it will be bundled into the app's lib/ dir by CMake at build time"
