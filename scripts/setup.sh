#!/usr/bin/env bash
#
# RBWA 开发工具链安装脚本
# --------------------------------------------------------------------------
# 用法:  sudo bash scripts/setup.sh
#
# 幂等: 可重复执行, 已安装的组件会跳过.
#
# 本脚本做三件事:
#   1. 用 pacman 安装 Flutter Linux 桌面构建依赖 (cmake, ninja)
#   2. 在用户态安装 Flutter SDK (clone 到 $HOME/flutter, 配置 PATH 到 ~/.zshrc)
#   3. 用 cargo 安装 flutter_rust_bridge_codegen v2 (与 pub 包版本对齐)
#
# 运行结束后请按提示 source ~/.zshrc 或新开终端, 然后回来继续工程脚手架.
# --------------------------------------------------------------------------

set -euo pipefail

# --- 颜色输出 ----------------------------------------------------------------
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; RED=''; NC=''
fi
info()  { printf "${BLUE}[INFO]${NC} %s\n"  "$*"; }
ok()    { printf "${GREEN}[OK]${NC} %s\n"    "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC} %s\n"     "$*" >&2; }

# --- 前置检查 ----------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    err "本脚本需要 sudo 执行 (pacman 安装系统依赖需要 root)."
    err "请使用:  sudo bash scripts/setup.sh"
    exit 1
fi

# 还原真实调用者, 避免 sudo 下 git/cargo 以 root 身份操作
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
if [[ -z "$REAL_HOME" || "$REAL_HOME" == "/" ]]; then
    err "无法解析真实用户家目录 (SUDO_USER=$REAL_USER)."
    exit 1
fi
info "以 root 运行, 真实用户: $REAL_USER  家目录: $REAL_HOME"

run_as_user() {
    sudo -u "$REAL_USER" -H env "HOME=$REAL_HOME" "$@"
}

# --- 1. 系统依赖 (pacman) ----------------------------------------------------
install_pacman() {
    local pkgs=("$@")
    local missing=()
    for pkg in "${pkgs[@]}"; do
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
            ok "已安装: $pkg"
        else
            missing+=("$pkg")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "pacman 安装缺失依赖: ${missing[*]}"
        pacman -S --needed --noconfirm "${missing[@]}"
        ok "系统依赖安装完成"
    else
        ok "系统依赖全部已存在, 跳过"
    fi
}

info "=== [1/4] 检查系统依赖 (pacman) ==="
# Flutter Linux 桌面构建链: clang/cmake/ninja/pkg-config + gtk3/glib2 开发库
# 本机 clang/llvm/pkg-config/gtk3 已具备, 这里只补 cmake/ninja; 其余用 --needed 兜底.
install_pacman cmake ninja pkg-config gtk3 glib2

# --- 2. Rust 工具链 ----------------------------------------------------------
info "=== [2/4] 检查 Rust 工具链 ==="
if command -v cargo >/dev/null 2>&1; then
    ok "cargo 已安装: $(run_as_user cargo --version)"
else
    err "未检测到 cargo. 请先安装 rustup (https://rustup.rs) 后重试."
    exit 1
fi
RUST_VER_MIN="1.70"
RUST_VER_NOW=$(run_as_user rustc --version | awk '{print $2}' | sed 's/-.*//')
info "当前 rustc: $RUST_VER_NOW  (最低要求 $RUST_VER_MIN)"

# --- 3. Flutter SDK ----------------------------------------------------------
info "=== [3/4] 检查 Flutter SDK ==="
# 允许用户通过环境变量指定 Flutter 安装位置, 默认 ~/develop/flutter
FLUTTER_DIR="${FLUTTER_DIR:-$REAL_HOME/develop/flutter}"
FLUTTER_BIN="$FLUTTER_DIR/bin/flutter"

# 判断 flutter 是否已在 PATH (以真实用户身份)
if run_as_user command -v flutter >/dev/null 2>&1; then
    ok "flutter 已在 PATH: $(run_as_user command -v flutter)"
    ok "版本: $(run_as_user flutter --version 2>/dev/null | head -1)"
elif [[ -x "$FLUTTER_BIN" ]]; then
    ok "Flutter SDK 位于 $FLUTTER_BIN (尚未在 PATH)"
    info "配置 PATH (见下文)..."
    _configure_flutter_path=true
else
    warn "未检测到 Flutter SDK."
    warn "请从 https://docs.flutter.dev/get-started/install/linux 下载,"
    warn "解压到 $FLUTTER_DIR 后重新运行本脚本, 或手动安装后设置 PATH."
    warn "（国内可使用镜像: export FLUTTER_STORAGE_BASE_URL=https://mirror.sjtu.edu.cn/flutter_infra）"
    warn "脚本将继续安装 flutter_rust_bridge_codegen; Flutter 装好后再运行 flutter doctor."
    _configure_flutter_path=false
fi

# 配置 PATH (幂等, 自动识别 fish/zsh/bash)
if [[ "${_configure_flutter_path:-false}" == "true" ]]; then
    _add_to_rc() {
        # $1 = file, $2 = marker, $3 = content
        local rcfile="$1" marker="$2" content="$3"
        touch "$rcfile"
        chown "$REAL_USER:$REAL_USER" "$rcfile"
        if grep -q "$marker" "$rcfile"; then
            ok "$rcfile 已包含 Flutter PATH 配置"
        else
            info "向 $rcfile 追加 Flutter PATH ..."
            printf '\n%s\n' "$content" >> "$rcfile"
            ok "已写入 $rcfile"
        fi
    }
    # fish
    FISH_CONF="$REAL_HOME/.config/fish/conf.d/rbwa.fish"
    mkdir -p "$(dirname "$FISH_CONF")"
    chown -R "$REAL_USER:$REAL_USER" "$(dirname "$FISH_CONF")"
    _add_to_rc "$FISH_CONF" "flutter/bin" \
        '# Flutter SDK (added by RBWA setup.sh)
fish_add_path -g -p "$HOME/develop/flutter/bin"
set -gx FLUTTER_STORAGE_BASE_URL "https://mirror.sjtu.edu.cn/flutter_infra"
set -gx PUB_HOSTED_URL "https://pub.flutter-io.cn"'
    # zsh / bash (兜底)
    _add_to_rc "$REAL_HOME/.zshrc" "flutter/bin" \
        '# Flutter SDK (added by RBWA setup.sh)
export PATH="$HOME/develop/flutter/bin:$PATH"
export FLUTTER_STORAGE_BASE_URL="https://mirror.sjtu.edu.cn/flutter_infra"
export PUB_HOSTED_URL="https://pub.flutter-io.cn"'
    warn "flutter 尚未在当前 shell PATH 中, 请重开终端或 source 对应配置文件."
fi

# --- 4. flutter_rust_bridge_codegen ------------------------------------------
info "=== [4/4] 安装 flutter_rust_bridge_codegen v2 ==="
# 版本必须与 pubspec.yaml 中 flutter_rust_bridge Dart 包对齐, 否则 codegen 与运行时不匹配.
FRB_VERSION="2.12.0"

if run_as_user command -v flutter_rust_bridge_codegen >/dev/null 2>&1; then
    INSTALLED_VER=$(run_as_user flutter_rust_bridge_codegen --version 2>/dev/null | head -1 || echo "")
    if echo "$INSTALLED_VER" | grep -q "$FRB_VERSION"; then
        ok "flutter_rust_bridge_codegen $FRB_VERSION 已安装"
    else
        warn "已安装版本: '$INSTALLED_VER' 与目标版本 $FRB_VERSION 不一致, 将升级/重装."
        run_as_user cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked --force
        ok "flutter_rust_bridge_codegen 已安装至 $FRB_VERSION"
    fi
else
    info "cargo install flutter_rust_bridge_codegen@$FRB_VERSION (首次安装, 可能需要数分钟) ..."
    run_as_user cargo install flutter_rust_bridge_codegen --version "$FRB_VERSION" --locked
    ok "flutter_rust_bridge_codegen $FRB_VERSION 安装完成"
fi

# --- 自检 --------------------------------------------------------------------
info "=== 自检 ==="
echo ""
echo "--- cargo install --list (FRB) ---"
run_as_user cargo install --list 2>/dev/null | grep -A2 flutter_rust_bridge || true
echo ""

if run_as_user command -v flutter >/dev/null 2>&1; then
    echo "--- flutter doctor ---"
    run_as_user flutter doctor || true
else
    warn "flutter 尚未在当前 PATH (sudo 环境). 请新开终端或 source ~/.zshrc 后手动运行: flutter doctor"
fi

echo ""
ok "=========================================="
ok "  RBWA 工具链安装完成"
ok "=========================================="
echo ""
printf "${YELLOW}下一步:${NC}\n"
echo "  1. 新开一个终端 (或 source ~/.zshrc) 让 flutter 进入 PATH"
echo "  2. 运行:  flutter doctor    # 确认无红线"
echo "  3. 回到 ZCode, 告知工具链就绪, 继续工程脚手架"
echo ""
