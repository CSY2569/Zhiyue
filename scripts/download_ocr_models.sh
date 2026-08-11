#!/usr/bin/env bash
# Download the PP-OCRv4 models for the RBWA full-page OCR engine
# (FEATURES 7.1.1: 下载脚本 + 完整性校验; 7.1.9: 高精度/快速双模式).
#
# Usage:
#   scripts/download_ocr_models.sh            # 高精度（默认，server 模型）
#   scripts/download_ocr_models.sh --fast     # 快速模式（mobile 模型）
#   scripts/download_ocr_models.sh --all      # 两种都下载
#   scripts/download_ocr_models.sh --all --dir <path>   # 下载到指定目录
#                                                     （打包脚本用）
#
# Packaged builds (deb/rpm/AppImage) ship the models next to the executable
# (build_packages.sh calls this with --dir); dev builds land in
# $XDG_DATA_HOME/RBWA/models (Linux default: ~/.local/share/RBWA/models) --
# the fallback directory the Rust core resolves via `app_data_dir`:
#
#   models/
#     cls.onnx               # 方向分类（两模式共用）
#     ppocr_keys_v1.txt      # 识别字符表（共用）
#     high_precision/        # ch_PP-OCRv4_*_server.onnx（高精度，~200MB）
#       det.onnx  rec.onnx
#     fast/                  # ch_PP-OCRv4_*_mobile.onnx（快速，~16MB）
#       det.onnx  rec.onnx
#
# Source: ModelScope 官方仓库 RapidAI/RapidOCR (v3.9.0). GitHub Releases
# 上没有模型资产（v1.3.0 等 tag 均无 assets），故以 ModelScope 为唯一源；
# 文件 sha256 已在本机下载后核对（cls 与 rapidocr-core 内置校验值一致）。
set -euo pipefail

MODE="${1:---precision}"
BASE_URL="https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.9.0"
MODELS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/RBWA/models"

# Optional --dir <path> overrides the destination (packaging use).
if [ "${2:-}" = "--dir" ]; then
  MODELS_DIR="${3:?--dir 需要一个目录参数}"
fi

# 源文件 → 本地路径 + sha256（det/rec 按模式子目录存放）。
PRECISION_DET="onnx/PP-OCRv4/det/ch_PP-OCRv4_det_server.onnx  cfa39a3f298f6d3fc71789834d15da36d11a6c59b489fc16ea4733728012f786"
PRECISION_REC="onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_server.onnx  6a2676219be9907c7fc9cf61ebaa843bf2898777def567925b78886fcd90c07a"
FAST_DET="onnx/PP-OCRv4/det/ch_PP-OCRv4_det_mobile.onnx       d2a7720d45a54257208b1e13e36a8479894cb74155a5efe29462512d42f49da9"
FAST_REC="onnx/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile.onnx       48fc40f24f6d2a207a2b1091d3437eb3cc3eb6b676dc3ef9c37384005483683b"
CLS="onnx/PP-OCRv4/cls/ch_ppocr_mobile_v2.0_cls_mobile.onnx   e47acedf663230f8863ff1ab0e64dd2d82b838fceb5957146dab185a89d6215c"
DICT="paddle/PP-OCRv4/rec/ch_PP-OCRv4_rec_mobile/ppocr_keys_v1.txt  28b2362ad4ab2dc38769aa72feb535e3a9ddb3fd2a7585a05920e6393b1dc7f7"

# 下载一个源文件到目标路径并做 sha256 校验（已有文件则跳过）。
download_one() {
  local src="$1" sha="$2" dest="$3"
  if [ -f "$dest" ]; then
    echo "已有 $(basename "$dest")，跳过"
    return
  fi
  mkdir -p "$(dirname "$dest")"
  echo "下载 $(basename "$dest") …"
  curl -fL --retry 3 -o "$dest.part" "$BASE_URL/$src"
  mv "$dest.part" "$dest"
  local actual
  actual="$(sha256sum "$dest" | cut -d' ' -f1)"
  if [ "$actual" != "$sha" ]; then
    echo "校验失败: $dest (期望 $sha, 实际 $actual)" >&2
    rm -f "$dest"
    exit 1
  fi
  echo "校验通过: $(basename "$dest")"
}

# 下载一套模式：det/rec 进模式子目录；cls 与字符表两模式共用，放根目录。
download_set() {
  local mode="$1" det_spec="$2" rec_spec="$3"
  local det_src det_sha rec_src rec_sha
  read -r det_src det_sha <<< "$det_spec"
  read -r rec_src rec_sha <<< "$rec_spec"
  download_one "$det_src" "$det_sha" "$MODELS_DIR/$mode/det.onnx"
  download_one "$rec_src" "$rec_sha" "$MODELS_DIR/$mode/rec.onnx"
}

case "$MODE" in
  --precision|--all)
    echo "下载高精度模型（server）…"
    download_set high_precision "$PRECISION_DET" "$PRECISION_REC"
    ;;
esac
case "$MODE" in
  --fast|--all)
    echo "下载快速模型（mobile）…"
    download_set fast "$FAST_DET" "$FAST_REC"
    ;;
esac

download_one "$(awk '{print $1}' <<<"$CLS")"  "$(awk '{print $2}' <<<"$CLS")"  "$MODELS_DIR/cls.onnx"
download_one "$(awk '{print $1}' <<<"$DICT")" "$(awk '{print $2}' <<<"$DICT")" "$MODELS_DIR/ppocr_keys_v1.txt"

case "$MODE" in
  --precision|--fast|--all) ;;
  *) echo "用法: $0 [--precision|--fast|--all]" >&2; exit 2;;
esac

echo "完成。模型目录: $MODELS_DIR"
echo "提示：首次扫描时引擎会懒加载模型（FEATURES 7.1.5）。"
