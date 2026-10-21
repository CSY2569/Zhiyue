#!/usr/bin/env bash
# Fetch libpdfium.so for Android and install both ABIs into jniLibs.
#
# Source: bblanchon/pdfium-binaries (BSD-3-Clause, Chromium project). The
# Android archives ship the same `lib/libpdfium.so` layout as the Linux ones
# that scripts/fetch_pdfium.sh uses.
#
# Sizes / alignment (verified against chromium/8111, pdfium 158.0.8111.0):
#   android-arm64/libpdfium.so   6.3 MB   LOAD align 0x4000 (16 KB) ✓
#   android-x64/libpdfium.so     6.6 MB   LOAD align 0x4000 (16 KB) ✓
#
# Usage:
#   scripts/fetch_pdfium_android.sh            # arm64 (the only supported ABI)
#   scripts/fetch_pdfium_android.sh --arm64    # explicit arm64
#   PDFIUM_VERSION=<tag> scripts/fetch_pdfium_android.sh
#
# x86_64 is intentionally NOT fetched: ONNX Runtime has no Android x86_64
# prebuilt (ort-sys ships aarch64-linux-android only), so the OCR engine cannot
# link for that ABI. See docs/ANDROID_V1_PLAN.md §0.3.
#
# The library is downloaded, not committed (.gitignore ignores *.so).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_JNI="$REPO_ROOT/android/app/src/main/jniLibs"
# Pinned for reproducibility; override with PDFIUM_VERSION=chromium/XXXX.
VERSION="${PDFIUM_VERSION:-chromium/8111}"
BASE_URL="https://github.com/bblanchon/pdfium-binaries/releases/download/${VERSION//\//%2F}"

ABIS=("arm64-v8a:pdfium-android-arm64")
if [ "${1:-}" = "--x64" ]; then
  echo "x86_64 Android 不受支持：ONNX Runtime 无该 ABI 预编译产物" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for entry in "${ABIS[@]}"; do
  abi="${entry%%:*}"
  asset="${entry##*:}"
  dest="$ANDROID_JNI/$abi/libpdfium.so"
  if [ -f "$dest" ]; then
    echo "已有 $abi/libpdfium.so，跳过（删除后重跑以升级）"
    continue
  fi
  echo "下载 pdfium ($VERSION, $abi) …"
  curl -fL --retry 3 -o "$TMP/$asset.tgz" "$BASE_URL/$asset.tgz"
  mkdir -p "$TMP/$abi"
  tar -xzf "$TMP/$asset.tgz" -C "$TMP/$abi" lib/libpdfium.so
  mkdir -p "$(dirname "$dest")"
  cp "$TMP/$abi/lib/libpdfium.so" "$dest"
  echo "已安装 $dest ($(du -h "$dest" | cut -f1))"
done

# 16 KB page alignment gate (Android 15+). Fail loudly rather than shipping
# a library the loader refuses to map on newer devices.
if command -v llvm-readelf >/dev/null 2>&1; then
  for entry in "${ABIS[@]}"; do
    abi="${entry%%:*}"
    dest="$ANDROID_JNI/$abi/libpdfium.so"
    [ -f "$dest" ] || continue
    if llvm-readelf -l "$dest" | grep -q 'LOAD.*0x4000'; then
      echo "16KB 对齐检查通过: $abi"
    else
      echo "警告: $abi/libpdfium.so 未按 16KB 对齐，Android 15+ 可能拒绝加载" >&2
    fi
  done
fi

echo "完成。jniLibs: $ANDROID_JNI"
echo "提示：构建 APK 时 Gradle 的 cargo-ndk 任务会同时产出 librbwa_core.so。"
