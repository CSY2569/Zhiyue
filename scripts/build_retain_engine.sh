#!/usr/bin/env bash
# 组装 RetainPDF 引擎目录（独立于安装包的开发/内置两用形态）。
#
# 产物布局（engine.rs 按此解析）：
#   <out>/python/bin/python3.11      uv 托管的独立 CPython 3.11（cp -aL 已去符号链接）
#   <out>/site-packages/             retainpdf-pipeline + 钉死依赖（PYTHONPATH 直连，不用 venv）
#   <out>/bin/typst                  Typst 0.15.1（上游 CI/Docker 钉死版本）
#   <out>/typst-packages/preview/{cmarker/0.1.10,mitex/0.2.7}/
#   <out>/fonts/SourceHanSerifSC-{Regular,Bold}.otf
#   <out>/engine.json                清单（bundled 由打包脚本改写为 true）
#
# 幂等：每步产物存在即跳过。环境变量：
#   RBWA_RETAIN_ENGINE_OUT   输出目录（默认 <repo>/engine-dev/retainpdf）
#   RBWA_ENGINE_PYPI_INDEX   PyPI 索引（默认 pypi.org；国内构建可设清华）
#   RBWA_PYTHON_MIRROR       python-build-standalone 镜像（可选覆盖，默认直连 GitHub）
#   RBWA_UV_BIN              uv 可执行文件（默认 PATH 查找）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO_ROOT/third_party/retainpdf"
OUT="${RBWA_RETAIN_ENGINE_OUT:-$REPO_ROOT/engine-dev/retainpdf}"
PYPI_INDEX="${RBWA_ENGINE_PYPI_INDEX:-https://pypi.org/simple}"
PYTHON_MIRROR="${RBWA_PYTHON_MIRROR:-}"
TYPST_VERSION=0.15.1
CMARKER_VERSION=0.1.10
MITEX_VERSION=0.2.7
UV_BIN="${RBWA_UV_BIN:-$(command -v uv)}"

PIPELINE_VERSION="$(grep -m1 '^version' "$VENDOR/pipeline/pyproject.toml" | cut -d'"' -f2)"
UPSTREAM_COMMIT="$(grep -m1 '上游提交' "$VENDOR/PIN.md" | sed 's/.*：//' | cut -d'（' -f1)"

log() { printf '\n== %s ==\n' "$*"; }
export UV_DEFAULT_INDEX="$PYPI_INDEX"

mkdir -p "$OUT"/{bin,site-packages,typst-packages/preview,fonts}

# 1. 独立 CPython 3.11（优先复制本机 uv 托管版本，缺省再下载）
if [ ! -x "$OUT/python/bin/python3.11" ]; then
  if PY_BIN="$("$UV_BIN" python find --only-managed 3.11 2>/dev/null)" && [ -n "$PY_BIN" ]; then
    log "复制本机 uv 托管 CPython 3.11：$PY_BIN"
  else
    log "下载独立 CPython 3.11${PYTHON_MIRROR:+（镜像：$PYTHON_MIRROR）}"
    UV_PYTHON_INSTALL_MIRROR="$PYTHON_MIRROR" UV_PYTHON_INSTALL_DIR="$OUT/.pyroot" \
      "$UV_BIN" python install 3.11
    PY_BIN="$(UV_PYTHON_INSTALL_DIR="$OUT/.pyroot" "$UV_BIN" python find 3.11)"
  fi
  cp -aL "$(dirname "$(dirname "$PY_BIN")")" "$OUT/python"
  rm -rf "$OUT/.pyroot"
else
  log "已存在独立 CPython，跳过"
fi
PY="$OUT/python/bin/python3.11"

# 2. 管线 wheel + 钉死依赖 → site-packages
if [ ! -f "$OUT/site-packages/retainpdf_pipeline/entrypoints/console.py" ]; then
  log "构建 retainpdf-pipeline $PIPELINE_VERSION wheel 并安装依赖"
  WHEEL_DIR="$OUT/.wheels"
  "$UV_BIN" build --wheel --out-dir "$WHEEL_DIR" "$VENDOR/pipeline"
  "$UV_BIN" pip install --python "$PY" --target "$OUT/site-packages" \
    "Pillow==10.4.0" "PyMuPDF==1.26.5" "pikepdf==10.13.0.post1" \
    "requests==2.32.5" "urllib3==2.5.0"
  "$UV_BIN" pip install --python "$PY" --target "$OUT/site-packages" --no-deps "$WHEEL_DIR"/*.whl
  rm -rf "$WHEEL_DIR"
else
  log "已存在 site-packages，跳过"
fi

# 3. Typst 二进制
if [ ! -x "$OUT/bin/typst" ]; then
  log "下载 Typst $TYPST_VERSION"
  TYPST_URL="https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-x86_64-unknown-linux-musl.tar.xz"
  TMP="$(mktemp -d)"
  # 直连卡死（速率过低）即中止并走 ghfast 回退。
  curl -fsSL --retry 3 --connect-timeout 15 --speed-limit 10240 --speed-time 30 \
    -o "$TMP/typst.tar.xz" "$TYPST_URL" \
    || curl -fsSL --retry 3 --speed-limit 10240 --speed-time 30 \
      -o "$TMP/typst.tar.xz" "https://ghfast.top/$TYPST_URL"
  tar -xJf "$TMP/typst.tar.xz" -C "$TMP"
  cp "$TMP/typst-x86_64-unknown-linux-musl/typst" "$OUT/bin/typst"
  chmod +x "$OUT/bin/typst"
  rm -rf "$TMP"
  "$OUT/bin/typst" --version
else
  log "已存在 typst，跳过"
fi

# 4. Typst @preview 包（渲染直取的 cmarker / mitex）
for pkg in "cmarker:${CMARKER_VERSION}" "mitex:${MITEX_VERSION}"; do
  name="${pkg%%:*}"; version="${pkg##*:}"
  dest="$OUT/typst-packages/preview/$name/$version"
  if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    log "已存在 @preview/$name:$version，跳过"
    continue
  fi
  log "下载 @preview/$name:$version"
  mkdir -p "$dest"
  TMP="$(mktemp -d)"
  curl -fsSL --retry 3 -o "$TMP/$name.tar.gz" "https://packages.typst.org/preview/${name}-${version}.tar.gz"
  tar -xzf "$TMP/$name.tar.gz" -C "$dest"
  rm -rf "$TMP"
done

# 5. 字体
cp -f "$VENDOR/fonts/SourceHanSerifSC-Regular.otf" "$VENDOR/fonts/SourceHanSerifSC-Bold.otf" "$OUT/fonts/"

# 6. 清单
# size_bytes lets the app report the footprint WITHOUT walking the tree on
# every status probe (a 300MB walk blocked the settings UI).
SIZE_BYTES="$(du -sb "$OUT" 2>/dev/null | cut -f1)"
SIZE_BYTES="${SIZE_BYTES:-0}"
cat > "$OUT/engine.json" <<JSON
{
  "retainpdf_pipeline": "$PIPELINE_VERSION",
  "upstream_commit": "$UPSTREAM_COMMIT",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "bundled": false,
  "size_bytes": $SIZE_BYTES
}
JSON

log "引擎组装完成：$OUT（$(du -sh "$OUT" | cut -f1)）"
cat "$OUT/engine.json"