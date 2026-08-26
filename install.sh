#!/usr/bin/env bash
# =============================================================================
# docker-ce-cn —— 国内一键安装 Docker Engine
#
# 仓库（apt 源）由 GitHub Actions 同步官方 docker-ce 并重签名后，
# 经 GitHub Release + ghproxy 等加速通道分发，本脚本负责：
#   下载并校验仓库包 → 配置本地 apt 源 → 安装 docker-ce 全家桶
#   → 自动启动服务 → 加入 docker 组 → 配置国内 registry 镜像加速
#
# 用法:
#   # 默认安装最新稳定版
#   sh -c "$(curl -fsSL https://github.com/MinimaxFlora/Docker_Private_source/raw/refs/heads/master/install.sh)"
#
#   # 下载后执行（支持参数）
#   curl -fsSL https://github.com/MinimaxFlora/Docker_Private_source/raw/refs/heads/master/install.sh -o install.sh
#   sudo bash install.sh --version 27.3
#
# 参数:
#   --version <VERSION>        指定 docker-ce 版本（如 27.3 或 27.3.1）
#   --mirror <URL>             GitHub 加速前缀（默认自动探测多个 ghproxy 镜像）
#   --registry-mirror <URL>    追加一个 docker 镜像加速地址（可重复）
#   --channel <stable>         通道，当前仅 stable
#   --no-autostart             不自动启动 docker 服务
#   --no-registry-mirror       不配置 registry 镜像加速
#   --dry-run                  只打印将执行的步骤，不实际安装
#   --help                     帮助
#
# 环境变量（与参数等效）:
#   PROJECT=owner/repo  TAG=latest  VERSION=27.3  DOWNLOAD_MIRROR=https://ghfast.top
#   REGISTRY_MIRRORS="a.com,b.com"  NO_AUTOSTART=1  NO_REGISTRY_MIRROR=1  DRY_RUN=1
# =============================================================================

# ---- sh 兼容层：sh -c "$(curl ...)" 会交给 dash 执行，这里强制切回 bash ----
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        if [ -f "$0" ] && [ -r "$0" ]; then
            exec bash "$0" "$@"
        fi
        # curl | sh 场景：脚本无 $0 文件，重新下载后交给 bash（页面域路径，绕开 raw CDN 缓存）
        for _u in \
            "https://github.com/MinimaxFlora/Docker_Private_source/raw/refs/heads/master/install.sh" \
            "https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_source@master/install.sh"; do
            if _s="$(curl -fsSL --max-time 20 "$_u" 2>/dev/null)"; then
                exec bash -c "$_s" bash "$@"
            fi
        done
        echo "无法重新获取脚本（网络受限？）" >&2
    else
        echo "此脚本需要 bash，请先安装 bash" >&2
    fi
    exit 1
fi
set -euo pipefail

# ----------------------------- 可配置项 -----------------------------
PROJECT="${PROJECT:-MinimaxFlora/Docker_Private_source}"   # 仓库（fork 后改这里）
TAG="${TAG:-latest}"                                    # Release tag（固定 latest，覆盖更新）
# GitHub 加速前缀候选（按序尝试；ghproxy 类镜像仅代理 /releases/download/ 下载）
DEFAULT_MIRRORS="ghfast.top gh-proxy.com ghproxy.net mirror.ghproxy.com gh-proxy.kejizero.xyz"
REPO_DIR="/opt/docker-ce-cn"                            # 本地 apt 仓库解压目录
KEYRING="/etc/apt/keyrings/docker-cn.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/docker-cn.list"
SUPPORTED_CODENAMES="trixie bookworm bullseye noble jammy focal"
SUPPORTED_ARCHS="amd64 arm64"
# 默认 docker pull 镜像加速（时效性强，可用 --registry-mirror 追加）
DEFAULT_REGISTRY_MIRRORS="https://docker.1ms.run https://docker.m.daocloud.io https://docker.1panel.live"

# ----------------------------- 参数解析 -----------------------------
VERSION="${VERSION:-}"
CHANNEL="${CHANNEL:-stable}"
DOWNLOAD_MIRROR="${DOWNLOAD_MIRROR:-}"
REGISTRY_MIRRORS="${REGISTRY_MIRRORS:-}"
NO_AUTOSTART="${NO_AUTOSTART:-0}"
NO_REGISTRY_MIRROR="${NO_REGISTRY_MIRROR:-0}"
DRY_RUN="${DRY_RUN:-0}"
EXTRA_MIRRORS=""

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="${2#v}"; shift ;;
        --mirror) DOWNLOAD_MIRROR="$2"; shift ;;
        --registry-mirror) EXTRA_MIRRORS="$EXTRA_MIRRORS $2"; shift ;;
        --channel) CHANNEL="$2"; shift ;;
        --no-autostart) NO_AUTOSTART=1 ;;
        --no-registry-mirror) NO_REGISTRY_MIRROR=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --help) usage ;;
        --*) echo "非法参数: $1" >&2; usage ;;
        *) echo "非法参数: $1" >&2; usage ;;
    esac
    shift $(( $# > 0 ? 1 : 0 ))
done

if [ "$CHANNEL" != "stable" ]; then
    echo "当前仅支持 stable 通道" >&2
    exit 1
fi

# ----------------------------- 工具函数 -----------------------------
command_exists() { command -v "$@" >/dev/null 2>&1; }

info()  { echo "INFO: $*"; }
warn()  { echo "WARNING: $*" >&2; }
die()   { echo "ERROR: $*" >&2; exit 1; }

user="$(id -un 2>/dev/null || true)"
sh_c='sh -c'
if [ "$user" != 'root' ]; then
    if command_exists sudo; then
        sh_c='sudo -E sh -c'
    elif command_exists su; then
        sh_c='su -c'
    else
        die "需要 root 权限（未找到 sudo/su）"
    fi
fi

# 下载 release 资产（多镜像自动探测）。$1=远端文件名 $2=本地路径 $3=超时秒
download_release_file() {
    local name="$1" dst="$2" timeout="${3:-600}" url candidates
    local release_url="https://github.com/$PROJECT/releases/download/$TAG/$name"
    if [ -n "$DOWNLOAD_MIRROR" ]; then
        candidates="$DOWNLOAD_MIRROR/$release_url"
    else
        candidates="$release_url"
        for m in $DEFAULT_MIRRORS; do
            candidates="$candidates https://$m/$release_url"
        done
    fi
    for url in $candidates; do
        if curl -fsSL --connect-timeout 8 --max-time "$timeout" -o "$dst" "$url"; then
            info "下载成功: $url"
            return 0
        fi
        warn "下载失败，尝试下一个源: $url"
    done
    return 1
}

# ----------------------------- 平台检测 -----------------------------
if [ "$DRY_RUN" = "1" ]; then
    echo "# --dry-run 模式：以下为将要执行的步骤 --"
fi

[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
. /etc/os-release
lsb_dist="${ID:-}"
dist_version="${VERSION_CODENAME:-}"
arch="$(dpkg --print-architecture 2>/dev/null || true)"

case "$lsb_dist" in
    debian|ubuntu) ;;
    *) die "不支持的发行版: '$lsb_dist'（本项目仅支持 Debian / Ubuntu）" ;;
esac
case " $SUPPORTED_CODENAMES " in
    *" $dist_version "*) ;;
    *) die "不支持的版本: '$dist_version'（支持: $SUPPORTED_CODENAMES）" ;;
esac
case " $SUPPORTED_ARCHS " in
    *" $arch "*) ;;
    *) die "不支持的架构: '$arch'（支持: $SUPPORTED_ARCHS）" ;;
esac
info "检测到 ${lsb_dist} ${dist_version} / ${arch}"

if [ "$DRY_RUN" = "1" ]; then
    echo "# 1. 下载仓库包 docker-ce-repo-$dist_version.tar 并校验 SHA256"
    echo "# 2. 解压到 $REPO_DIR"
    echo "# 3. 安装密钥到 $KEYRING，写入 $SOURCE_FILE"
    echo "# 4. apt-get update && 安装 docker-ce 全家桶${VERSION:+（版本 $VERSION）}"
    echo "# 5. systemctl enable --now docker${NO_AUTOSTART:+（已跳过）} + usermod -aG docker"
    echo "# 6. 配置 registry 镜像加速${NO_REGISTRY_MIRROR:+（已跳过）}"
    exit 0
fi

# ----------------------------- 下载并校验仓库包 -----------------------------
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
tar_name="docker-ce-repo-$dist_version.tar"
info "下载仓库: $tar_name（若网络慢，可 --mirror 指定加速前缀）"
download_release_file "$tar_name" "$tmpdir/$tar_name" 900 || die "仓库包下载失败，请检查网络或换 --mirror"
download_release_file "$tar_name.sha256" "$tmpdir/$tar_name.sha256" 60 || die "校验文件下载失败"

expected="$(awk '{print $1}' "$tmpdir/$tar_name.sha256")"
actual="$(sha256sum "$tmpdir/$tar_name" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] || die "SHA256 校验失败（可能下载不完整）"
info "SHA256 校验通过"

# ----------------------------- 安装 apt 源 -----------------------------
$sh_c "install -d -m 0755 $REPO_DIR"
$sh_c "tar -xf $tmpdir/$tar_name -C $REPO_DIR"
$sh_c "install -d -m 0755 /etc/apt/keyrings"
if command_exists gpg; then
    $sh_c "gpg --dearmor < $REPO_DIR/keyring/docker-ce-cn.asc > $KEYRING 2>/dev/null || cp $REPO_DIR/keyring/docker-ce-cn.asc $KEYRING"
else
    $sh_c "cp $REPO_DIR/keyring/docker-ce-cn.asc $KEYRING"
fi

if [ -f "$SOURCE_FILE" ]; then
    $sh_c "cp $SOURCE_FILE $SOURCE_FILE.bak.\$(date +%s)"
    info "已备份原 $SOURCE_FILE"
fi
# file: 源 —— 无第三方网络依赖，仓库内容来自已校验的本地文件
$sh_c "echo 'deb [signed-by=$KEYRING] file:$REPO_DIR $dist_version stable' > $SOURCE_FILE"

# ----------------------------- 安装 Docker -----------------------------
$sh_c "apt-get -qq update" || die "apt-get update 失败"
pkgs="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-model-plugin"
apt_flags="-y -qq"

if [ -n "$VERSION" ]; then
    info "查找版本 '$VERSION' ..."
    ver_esc="$(printf '%s' "$VERSION" | sed 's/[.[\*^$]/\\&/g')"
    pkg_version="$(apt-cache madison docker-ce | awk -v p="^[0-9]+:${ver_esc}" '$2 ~ p {print $2}' | sort -V | tail -1 || true)"
    if [ -z "$pkg_version" ]; then
        echo "错误: 仓库中未找到 docker-ce 版本 '$VERSION'，可用版本:" >&2
        apt-cache madison docker-ce | head -15 >&2 || true
        exit 1
    fi
    cli_pkg_version="$(apt-cache madison docker-ce-cli | awk -v p="^[0-9]+:${ver_esc}" '$2 ~ p {print $2}' | sort -V | tail -1 || true)"
    pkgs="docker-ce=$pkg_version"
    [ -n "$cli_pkg_version" ] && pkgs="$pkgs docker-ce-cli=$cli_pkg_version"
    pkgs="$pkgs containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-model-plugin"
    apt_flags="$apt_flags --allow-downgrades"
    info "安装 $pkgs"
else
    info "安装最新稳定版: $pkgs"
fi

$sh_c "DEBIAN_FRONTEND=noninteractive apt-get $apt_flags install $pkgs" || die "安装失败"

if [ -f "$REPO_DIR/repo-version.txt" ]; then
    echo "----------------------------------------"
    echo "仓库同步信息（$REPO_DIR/repo-version.txt）:"
    cat "$REPO_DIR/repo-version.txt"
    echo "----------------------------------------"
fi

# ----------------------------- 启动服务 + 加入 docker 组 -----------------------------
if [ "$NO_AUTOSTART" != "1" ]; then
    if command_exists systemctl; then
        if $sh_c "systemctl enable --now docker 2>/dev/null"; then
            info "docker 服务已启用并启动"
        else
            warn "无法自动启动 docker 服务（可稍后手动 systemctl start docker）"
        fi
    else
        warn "未检测到 systemd，跳过自动启动"
    fi
else
    info "已跳过自动启动（--no-autostart）"
fi

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    $sh_c "usermod -aG docker '$SUDO_USER'" 2>/dev/null || true
    info "已将用户 $SUDO_USER 加入 docker 组，重新登录后免 sudo 使用 docker"
fi

# ----------------------------- registry 镜像加速 -----------------------------
if [ "$NO_REGISTRY_MIRROR" != "1" ]; then
    mirrors="$DEFAULT_REGISTRY_MIRRORS $EXTRA_MIRRORS"
    [ -n "$REGISTRY_MIRRORS" ] && mirrors="$mirrors $(printf '%s' "$REGISTRY_MIRRORS" | tr ',' ' ')"
    mirrors="$(printf '%s\n' $mirrors | awk 'NF' | sort -u | tr '\n' ' ')"
    if [ -n "$mirrors" ]; then
        info "配置 registry 镜像加速: $mirrors"
        $sh_c "install -d -m 0755 /etc/docker"
        daemon_json="/etc/docker/daemon.json"
        [ -f "$daemon_json" ] && $sh_c "cp $daemon_json $daemon_json.bak.\$(date +%s)" && info "已备份原 $daemon_json"
        if command_exists python3; then
            # python3 合并（保留原配置，去重追加 registry-mirrors）
            cat > "$tmpdir/merge-daemon.py" <<PYEOF
import json, os
path = "$daemon_json"
new = """$mirrors""".split()
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}
cur = data.get("registry-mirrors") or []
for m in new:
    if m not in cur:
        cur.append(m)
data["registry-mirrors"] = cur
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF
            $sh_c "chmod a+r $tmpdir/merge-daemon.py && python3 $tmpdir/merge-daemon.py"
        elif command_exists jq; then
            mirrors_json="$(printf '%s' "$mirrors" | awk '{printf "[\""; for(i=1;i<=NF;i++){printf "%s%s",(i>1?"\",\"":""),$i} printf "\"]"}')"
            if [ -f "$daemon_json" ] && [ -s "$daemon_json" ]; then
                $sh_c "jq --argjson m '$mirrors_json' '.registry-mirrors = ((.registry-mirrors // []) + \$m | unique)' $daemon_json > $daemon_json.new && mv $daemon_json.new $daemon_json"
            else
                $sh_c "echo '{\"registry-mirrors\": $mirrors_json}' > $daemon_json"
            fi
        else
            # 兜底：无 python3/jq，备份后仅写入 registry-mirrors
            warn "未找到 python3/jq，$daemon_json 将仅包含 registry-mirrors（原配置已备份）"
            m="$(printf '%s' "$mirrors" | awk '{for(i=1;i<=NF;i++) printf "%s%s", (i>1?", ":""), "\""$i"\""}')"
            $sh_c "echo '{\"registry-mirrors\": [$m]}' > $daemon_json"
        fi
        if [ "$NO_AUTOSTART" != "1" ] && command_exists systemctl; then
            $sh_c "systemctl restart docker 2>/dev/null" || true
            info "已重启 docker 使加速生效"
        fi
    fi
else
    info "已跳过 registry 镜像加速（--no-registry-mirror）"
fi

# ----------------------------- 完成 -----------------------------
echo
echo "================================================================================"
echo "  Docker 安装完成！"
if command_exists docker; then
    set +e
    docker version 2>/dev/null
    set -e
fi
echo
echo "  - 仓库:  $PROJECT (tag: $TAG)"
echo "  - 发行版: ${lsb_dist} ${dist_version} / ${arch}"
echo "  - 提示:  非 root 用户需重新登录后生效 docker 组权限"
echo "  - 加速:  /etc/docker/daemon.json 中的 registry-mirrors 可随时增删"
echo "================================================================================"
