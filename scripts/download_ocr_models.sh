#!/usr/bin/env bash
# Download the PP-OCRv4 models for the RBWA full-page OCR engine
# (FEATURES 7.1.1: 下载脚本 + 完整性校验; 7.1.9: 高精度/快速双模式).
#
# Usage:
#   scripts/download_ocr_models.sh            # 高精度（默认，server 模型）
#   scripts/download_ocr_models.sh --fast     # 快速模式（mobile + int8）
#   scripts/download_ocr_models.sh --all      # 两种都下载
#
# Models land in $XDG_DATA_HOME/RBWA/models (Linux default:
# ~/.local/share/RBWA/models) -- the same directory the Rust core resolves
# via `app_data_dir`.
#
# NOTE: the engine itself is a stub until rapidocr-core is integrated (M5
# follow-up); the URLs below are the RapidOCR model releases. Verify the
# sha256 sums against the release page before first use.
set -euo pipefail

MODE="${1:---precision}"
BASE_URL="https://github.com/RapidAI/RapidOCR/releases/download/v1.3.0"
MODELS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/RBWA/models"

# Model files per mode (det / cls / rec + the rec character table).
declare -A PRECISION=(
  [det]="ch_PP-OCRv4_det_infer.tar.gz  <sha256-of-server-det>"
  [cls]="ch_ppocr_mobile_v2.0_cls_infer.tar.gz  <sha256-of-cls>"
  [rec]="ch_PP-OCRv4_rec_infer.tar.gz  <sha256-of-server-rec>"
)
declare -A FAST=(
  [det]="ch_PP-OCRv4_mobile_det_infer.tar.gz  <sha256-of-mobile-det>"
  [cls]="ch_ppocr_mobile_v2.0_cls_infer.tar.gz  <sha256-of-cls>"
  [rec]="ch_PP-OCRv4_mobile_rec_infer.tar.gz  <sha256-of-mobile-rec>"
)

mkdir -p "$MODELS_DIR"

download_one() {
  local file="$1" expected_sha="$2" dir="$3"
  local target="$MODELS_DIR/$file"
  if [ -f "$target" ]; then
    echo "已有 $file，跳过下载"
    return
  fi
  echo "下载 $file ..."
  curl -fL --retry 3 -o "$target.part" "$BASE_URL/$file"
  mv "$target.part" "$target"

  if [ "$expected_sha" != "<sha256-of-*" ]; then
    local actual
    actual="$(sha256sum "$target" | cut -d' ' -f1)"
    if [ "$actual" != "$expected_sha" ]; then
      echo "校验失败: $file (期望 $expected_sha, 实际 $actual)" >&2
      rm -f "$target"
      exit 1
    fi
    echo "校验通过: $file"
  else
    echo "警告: $file 未配置 sha256 校验和，请对照发布页核对" >&2
  fi
}

download_set() {
  local -n models="$1"
  for part in det cls rec; do
    read -r file sha <<< "${models[$part]}"
    download_one "$file" "$sha" "$MODELS_DIR"
  done
}

case "$MODE" in
  --precision|--all) echo "下载高精度模型（server）…"; download_set PRECISION;;
esac
case "$MODE" in
  --fast|--all) echo "下载快速模型（mobile + int8）…"; download_set FAST;;
  --precision) ;;
  *) echo "用法: $0 [--precision|--fast|--all]" >&2; exit 2;;
esac

echo "完成。模型目录: $MODELS_DIR"
