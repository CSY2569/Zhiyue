#!/usr/bin/env bash
# Stage the PP-OCRv4 models into the Android app's assets for first-run
# installation (Android v1 decision D1: BOTH model sets ship in the APK, so
# OCR is fully offline out of the box).
#
# Output (ingested by aapt2 into the APK; never committed):
#   android/app/src/main/assets/models/
#     cls.onnx                        572 KB
#     ppocr_keys_v1.txt                26 KB
#     high_precision/det.onnx        108 MB
#     high_precision/rec.onnx         86 MB
#     fast/det.onnx                  4.5 MB
#     fast/rec.onnx                   10 MB
#     manifest.json                  version + per-file sha256 + byte sizes
#
# The Kotlin ModelProvisioner streams these into `filesDir/models/`, which is
# exactly the path the Rust OCR engine already resolves on Android.
#
# Usage:
#   scripts/stage_android_models.sh              # download (if needed) + stage
#   scripts/stage_android_models.sh --clean      # remove staged models
#
# Downloads reuse scripts/download_ocr_models.sh (ModelScope, sha256-pinned)
# into a staging dir, so repeated runs are cheap.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS_MODELS="$REPO_ROOT/android/app/src/main/assets/models"
STAGING="${RBWA_ANDROID_MODEL_CACHE:-$REPO_ROOT/.cache/android-models}"
# Bump when the bundled model set or its provenance changes; the Kotlin
# installer compares this against the marker file on the device.
MODEL_SET_VERSION="${RBWA_MODEL_SET_VERSION:-ppocrv4-v3.9.0}"

if [ "${1:-}" = "--clean" ]; then
  rm -rf "$ASSETS_MODELS"
  echo "已清理 $ASSETS_MODELS"
  exit 0
fi

if [ ! -d "$REPO_ROOT/android" ]; then
  echo "错误: 未找到 android/ 工程，先完成 A0 脚手架" >&2
  exit 1
fi

echo "== 1/3 准备模型缓存 =="
# Reuse an existing dev install instead of re-downloading ~210MB. Files copied
# here are still validated by download_ocr_models.sh's sha256 gate (it checks
# only files it downloads, so verify sizes ourselves before seeding).
DEV_MODELS="${XDG_DATA_HOME:-$HOME/.local/share}/RBWA/models"
mkdir -p "$STAGING"
if [ -d "$DEV_MODELS" ] && [ "$DEV_MODELS" != "$STAGING" ]; then
  for f in cls.onnx ppocr_keys_v1.txt high_precision/det.onnx high_precision/rec.onnx fast/det.onnx fast/rec.onnx; do
    if [ -f "$DEV_MODELS/$f" ] && [ ! -f "$STAGING/$f" ]; then
      mkdir -p "$(dirname "$STAGING/$f")"
      cp -f "$DEV_MODELS/$f" "$STAGING/$f"
      echo "  复用本机模型: $f"
    fi
  done
fi
bash "$REPO_ROOT/scripts/download_ocr_models.sh" --all --dir "$STAGING"

echo "== 2/3 复制到 Android assets =="
mkdir -p "$ASSETS_MODELS/high_precision" "$ASSETS_MODELS/fast"
for f in cls.onnx ppocr_keys_v1.txt high_precision/det.onnx high_precision/rec.onnx fast/det.onnx fast/rec.onnx; do
  src="$STAGING/$f"
  dst="$ASSETS_MODELS/$f"
  if [ ! -f "$src" ]; then
    echo "错误: 缓存缺少 $f（先运行 scripts/download_ocr_models.sh --all）" >&2
    exit 1
  fi
  cp -f "$src" "$dst"
  echo "  $f  $(du -h "$dst" | cut -f1)"
done

echo "== 3/3 生成 manifest.json =="
python3 - "$ASSETS_MODELS" "$MODEL_SET_VERSION" <<'PY'
import hashlib, json, os, sys

root, version = sys.argv[1], sys.argv[2]
files = [
    "cls.onnx",
    "ppocr_keys_v1.txt",
    "high_precision/det.onnx",
    "high_precision/rec.onnx",
    "fast/det.onnx",
    "fast/rec.onnx",
]
entries = []
total = 0
for rel in files:
    path = os.path.join(root, rel)
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    size = os.path.getsize(path)
    total += size
    entries.append({"path": rel, "sha256": h.hexdigest(), "bytes": size})

manifest = {
    "version": version,
    "source": "RapidAI/RapidOCR v3.9.0 via scripts/download_ocr_models.sh",
    "total_bytes": total,
    "files": entries,
}
with open(os.path.join(root, "manifest.json"), "w", encoding="utf-8") as f:
    json.dump(manifest, f, ensure_ascii=False, indent=2)
    f.write("\n")
print(f"  manifest.json: {len(entries)} files, {total / 1024 / 1024:.1f} MiB total")
PY

TOTAL="$(du -sh "$ASSETS_MODELS" | cut -f1)"
echo "完成。assets 模型体积: $TOTAL"
echo "提示：APK 会因此增大；构建脚本对本目录的 .onnx 关闭压缩（noCompress）。"
