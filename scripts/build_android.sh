#!/usr/bin/env bash
# Build the Android app (APK / AAB) with the Rust core, pdfium and bundled
# OCR models.
#
# Prerequisites (one-time):
#   - Android SDK + NDK r28 (set ANDROID_HOME or sdk.dir in android/local.properties)
#   - rustup target add aarch64-linux-android
#   - cargo install cargo-ndk
#   - bash scripts/fetch_pdfium_android.sh
#   - bash scripts/stage_android_models.sh
#
# Usage:
#   scripts/build_android.sh                     # debug APK (arm64 only)
#   scripts/build_android.sh --release           # release APK, split per ABI
#   scripts/build_android.sh --release --appbundle
#   scripts/build_android.sh --release
#
# ABI: arm64-v8a only. ONNX Runtime (needed by the OCR engine) ships no
# Android x86_64 prebuilt, so x86_64 emulator builds are not supported.
#
# Signing: put `storeFile/storePassword/keyAlias/keyPassword` in
# android/key.properties (gitignored). Without it the release build falls back
# to debug signing so it still installs for testing.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$REPO_ROOT/android"
JNI_DIR="$ANDROID_DIR/app/src/main/jniLibs"
MODELS_DIR="$ANDROID_DIR/app/src/main/assets/models"

MODE="debug"
TARGET="apk"
for arg in "$@"; do
  case "$arg" in
    --release) MODE="release" ;;
    --debug) MODE="debug" ;;
    --appbundle) TARGET="appbundle" ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

cd "$REPO_ROOT"

# --- preflight ---------------------------------------------------------------
missing=0
for f in "$JNI_DIR/arm64-v8a/libpdfium.so"; do
  if [ ! -f "$f" ]; then
    echo "缺少 $f — 先运行 scripts/fetch_pdfium_android.sh" >&2
    missing=1
  fi
done
if [ ! -f "$MODELS_DIR/manifest.json" ]; then
  echo "缺少 $MODELS_DIR/manifest.json — 先运行 scripts/stage_android_models.sh" >&2
  missing=1
fi
if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "缺少 cargo-ndk — cargo install cargo-ndk" >&2
  missing=1
fi
if [ -z "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" ] && [ ! -f "$ANDROID_DIR/local.properties" ]; then
  echo "未找到 Android SDK：设置 ANDROID_HOME 或在 android/local.properties 写 sdk.dir" >&2
  missing=1
fi
[ "$missing" -eq 0 ] || exit 1

# --- release signing ---------------------------------------------------------
SIGN_ARGS=()
if [ "$MODE" = "release" ] && [ -f "$ANDROID_DIR/key.properties" ]; then
  echo "使用 android/key.properties 签名"
else
  if [ "$MODE" = "release" ]; then
    echo "提示: 未找到 android/key.properties，release 包使用 debug 签名（仅测试用）"
  fi
fi

# --- models must not be stale when the source tree changed -------------------
if [ "$(find "$MODELS_DIR" -name '*.onnx' | wc -l)" -lt 4 ]; then
  echo "assets 模型不完整（需要 4 个 onnx + cls + 字典），重跑 scripts/stage_android_models.sh" >&2
  exit 1
fi

# --- build -------------------------------------------------------------------
PROFILE_FLAG=""
if [ "$MODE" = "release" ]; then PROFILE_FLAG="--release"; fi

TARGET_PLATFORM="android-arm64"

echo "== flutter build $TARGET ($MODE, $TARGET_PLATFORM) =="
if [ "$TARGET" = "appbundle" ]; then
  flutter build appbundle "$PROFILE_FLAG" \
    --target-platform "$TARGET_PLATFORM" \
    --android-project-arg "rbwaCargoProfile=$MODE"
else
  flutter build apk "$PROFILE_FLAG" \
    --target-platform "$TARGET_PLATFORM" \
    --android-project-arg "rbwaCargoProfile=$MODE"
fi

echo "== 产物 =="
ls -lh "$REPO_ROOT/build/app/outputs/flutter-apk/" 2>/dev/null || true
ls -lh "$REPO_ROOT/build/app/outputs/bundle/" 2>/dev/null || true

# --- 16 KB alignment gate ----------------------------------------------------
if command -v llvm-readelf >/dev/null 2>&1; then
  for so in "$JNI_DIR"/*/*.so; do
    [ -f "$so" ] || continue
    if ! llvm-readelf -l "$so" | grep -q 'LOAD.*0x4000'; then
      echo "警告: $(basename "$(dirname "$so")")/$(basename "$so") 未按 16KB 对齐" >&2
    fi
  done
fi
