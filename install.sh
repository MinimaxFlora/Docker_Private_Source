#!/usr/bin/env bash
# =============================================================================
# docker-ce-cn —— 国内一键安装 Docker Engine
#
# 仓库（apt / yum 源）由 GitHub Actions 同步官方 docker-ce 并重签名后，
# 经 GitHub Release + ghproxy 等加速通道分发，本脚本负责：
#   下载并校验仓库包 → 配置本地 apt / yum 源 → 安装 docker-ce 全家桶
#   → 自动启动服务 → 加入 docker 组 → 配置国内 registry 镜像加速
#
# 支持:
#   Debian 11/12/13 (bullseye/bookworm/trixie)、Ubuntu 20.04/22.04/24.04
#   (focal/jammy/noble)、CentOS 7/9/10、Rocky Linux 9/10、RHEL 9/10、
#   AlmaLinux 9/10、Fedora 43/44（amd64 / arm64）
#
# 用法:
#   # 默认安装最新稳定版
#   sh -c "$(curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh)"
#
#   # 下载后执行（支持参数）
#   curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh -o install.sh
#   sudo bash install.sh --version 29.7
#
# 参数:
#   --version <VERSION>        指定 docker-ce 版本（如 29.7 或 29.7.2）
#   --mirror <URL>             GitHub 加速前缀（默认自动探测多个 ghproxy 镜像）
#   --registry-mirror <URL>    追加一个 docker 镜像加速地址（可重复）
#   --channel <stable>         通道，当前仅 stable
#   --no-autostart             不自动启动 docker 服务
#   --no-registry-mirror       不配置 registry 镜像加速
#   --force                    已安装时也强制执行（重装/升级）
#   --dry-run                  只打印将执行的步骤，不实际安装
#   --help                     帮助
#
# 环境变量（与参数等效）:
#   PROJECT=owner/repo  TAG=latest  VERSION=29.7  DOWNLOAD_MIRROR=https://ghfast.top
#   CHINA_MIRROR=https://你的加速站  REGISTRY_MIRRORS="a.com,b.com"
#   NO_AUTOSTART=1  NO_REGISTRY_MIRROR=1  DRY_RUN=1
# =============================================================================

# ---- sh 兼容层：sh -c "$(curl ...)" 会交给 dash 执行，这里强制切回 bash ----
if [ -z "${BASH_VERSION:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        if [ -f "$0" ] && [ -r "$0" ]; then
            exec bash "$0" "$@"
        fi
        # curl | sh 场景：脚本无 $0 文件，重新下载后交给 bash（多源：页面域 + jsDelivr + 加速站）
        for _u in \
            "https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh" \
            "https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_Source@master/install.sh" \
            "https://ghfast.top/https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh"; do
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
PROJECT="${PROJECT:-MinimaxFlora/Docker_Private_Source}"   # 仓库（fork 后改这里）
TAG="${TAG:-latest}"                                    # Release tag（固定 latest，覆盖更新）
# GitHub 加速前缀候选（按序尝试；ghproxy 类镜像仅代理 /releases/download/ 下载）
DEFAULT_MIRRORS="ghfast.top gh-proxy.com ghproxy.net mirror.ghproxy.com gh-proxy.kejizero.xyz"
# 国内网络默认加速站（自动检测命中国内时优先使用；可 --mirror 或环境变量 CHINA_MIRROR 覆盖）
CHINA_MIRROR="${CHINA_MIRROR:-https://gh-proxy.kejizero.xyz}"
REPO_DIR="/opt/docker-ce-cn"                            # 本地 apt/yum 仓库解压目录
KEYRING="/etc/apt/keyrings/docker-cn.gpg"
SOURCE_FILE="/etc/apt/sources.list.d/docker-cn.list"
RPM_REPO_FILE="/etc/yum.repos.d/docker-cn.repo"
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
FORCE="${FORCE:-0}"
EXTRA_MIRRORS=""

usage() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
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
        --force) FORCE=1 ;;
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

# 颜色输出：终端时启用（INFO 绿 / WARN 黄 / ERROR 红），
# 重定向到文件或 NO_COLOR=1 时自动无色，便于日志落盘
if [ -z "${NO_COLOR:-}" ] && { [ -t 1 ] || [ -t 2 ]; }; then
    C_INFO="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_RESET="\033[0m"
else
    C_INFO=""; C_WARN=""; C_ERR=""; C_RESET=""
fi
info()  { echo -e "${C_INFO}INFO: $*${C_RESET}"; }
warn()  { echo -e "${C_WARN}WARN: $*${C_RESET}" >&2; }
die()   { echo -e "${C_ERR}ERROR: $*${C_RESET}" >&2; exit 1; }

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

# 检测是否为国内网络：境外可达（google 通）→ 非国内；
# 境外不通但国内可达（baidu 通）→ 国内；都测不通（网络异常）→ 按国内容错走加速站
IS_CHINA=""
is_china_network() {
    if [ -n "$IS_CHINA" ]; then
        [ "$IS_CHINA" = "1" ] && return 0 || return 1
    fi
    if curl -fsSL -m 5 -o /dev/null https://www.google.com/generate_204 2>/dev/null; then
        IS_CHINA=0
        return 1
    fi
    if curl -fsSL -m 5 -o /dev/null https://www.baidu.com 2>/dev/null; then
        IS_CHINA=1
        return 0
    fi
    IS_CHINA=1
    return 0
}

# 下载 release 资产（多镜像自动探测）。$1=远端文件名 $2=本地路径 $3=超时秒
download_release_file() {
    local name="$1" dst="$2" timeout="${3:-600}" url candidates
    local release_url="https://github.com/$PROJECT/releases/download/$TAG/$name"
    if [ -n "$DOWNLOAD_MIRROR" ]; then
        # 用户显式指定：只用该加速前缀
        candidates="$DOWNLOAD_MIRROR/$release_url"
    elif is_china_network; then
        # 国内网络：默认加速站优先，其余镜像兜底，直连最后
        info "检测到国内网络，优先使用加速站 $CHINA_MIRROR"
        candidates="$CHINA_MIRROR/$release_url"
        for m in $DEFAULT_MIRRORS; do
            [ "https://$m" = "$CHINA_MIRROR" ] || candidates="$candidates https://$m/$release_url"
        done
        candidates="$candidates $release_url"
    else
        # 海外网络：直连优先，镜像兜底
        info "检测到海外网络，直连 GitHub"
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
# 用子 shell 读取 os-release，避免其 VERSION 字段（如 Debian 的 "12 (bookworm)"）
# 污染本脚本的 --version 参数变量 VERSION
[ -r /etc/os-release ] || die "无法读取 /etc/os-release"
lsb_dist="$(. /etc/os-release && printf '%s' "${ID:-}")"
ver_id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

case "$lsb_dist" in
    debian|ubuntu) PKG_KIND=deb ;;
    centos|rocky|rhel|almalinux|fedora) PKG_KIND=rpm ;;
    *) die "不支持的发行版: '$lsb_dist'（支持: Debian/Ubuntu、Rocky/CentOS/RHEL/AlmaLinux/Fedora）" ;;
esac

if [ "$PKG_KIND" = "deb" ]; then
    dist_version="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
    if [ -z "$dist_version" ] && command_exists lsb_release; then
        dist_version="$(lsb_release --codename 2>/dev/null | cut -f2 || true)"
    fi
    arch="$(dpkg --print-architecture 2>/dev/null || true)"
    case " $SUPPORTED_CODENAMES " in
        *" $dist_version "*) ;;
        *) die "不支持的版本: '$dist_version'（支持: $SUPPORTED_CODENAMES）" ;;
    esac
    case " $SUPPORTED_ARCHS " in
        *" $arch "*) ;;
        *) die "不支持的架构: '$arch'（支持: $SUPPORTED_ARCHS）" ;;
    esac
    info "检测到 ${lsb_dist} ${dist_version} / ${arch}"
else
    case "$lsb_dist" in
        fedora)
            case "$ver_id" in
                43|44) rpm_id="fedora-$ver_id" ;;
                *) die "不支持的 Fedora 版本: '$ver_id'（支持: 43/44，新版本请先更新同步矩阵）" ;;
            esac ;;
        centos|rocky|rhel|almalinux)
            case "$ver_id" in
                7*) rpm_id=el7 ;;
                9*) rpm_id=el9 ;;
                10*) rpm_id=el10 ;;
                *) die "不支持的版本: '$lsb_dist $ver_id'（支持: 7/9/10 系）" ;;
            esac ;;
    esac
    arch="$(uname -m 2>/dev/null || true)"
    case "$arch" in
        x86_64|aarch64) ;;
        *) die "不支持的架构: '$arch'（支持: x86_64 / aarch64）" ;;
    esac
    info "检测到 ${lsb_dist} ${ver_id} / ${arch}（仓库: $rpm_id）"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "# --dry-run 模式：以下为将要执行的步骤 --"
    if [ "$PKG_KIND" = "deb" ]; then
        echo "# 1. 下载仓库包 docker-ce-repo-$dist_version.tar 并校验 SHA256"
        echo "# 2. 解压到 $REPO_DIR，安装公钥，写入 $SOURCE_FILE（file: apt 源）"
        echo "# 3. apt-get update && 安装 docker-ce 全家桶${VERSION:+（版本 $VERSION）}"
    else
        echo "# 1. 下载仓库包 docker-ce-repo-rpm-$rpm_id.tar 并校验 SHA256"
        echo "# 2. 解压到 $REPO_DIR，写入 $RPM_REPO_FILE（file:// yum 源）"
        echo "# 3. dnf/yum install docker-ce 全家桶${VERSION:+（版本 $VERSION）}"
    fi
    echo "# 4. systemctl enable --now docker${NO_AUTOSTART:+（已跳过）} + usermod -aG docker"
    echo "# 5. 配置 registry 镜像加速${NO_REGISTRY_MIRROR:+（已跳过）}"
    exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# 下载并校验仓库包（自动重试：GitHub CDN 可能缓存旧版同名资产，重试可命中新内容）
download_and_verify() {
    local name="$1" retry=0 expected actual
    while :; do
        download_release_file "$name" "$tmpdir/$name" 900 || die "仓库包下载失败，请检查网络或换 --mirror"
        download_release_file "$name.sha256" "$tmpdir/$name.sha256" 60 || die "校验文件下载失败"
        expected="$(awk '{print $1}' "$tmpdir/$name.sha256")"
        actual="$(sha256sum "$tmpdir/$name" | awk '{print $1}')"
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            info "SHA256 校验通过"
            return 0
        fi
        retry=$((retry + 1))
        if [ "$retry" -ge 3 ]; then
            die "SHA256 校验失败（可能下载不完整，或 GitHub CDN 仍缓存旧版仓库包，请稍候数分钟重试）"
        fi
        warn "SHA256 校验失败（第 $retry 次），清除缓存文件后重新下载..."
        rm -f "$tmpdir/$name" "$tmpdir/$name.sha256"
        sleep 15
    done
}

# ===========================================================================
# deb 流程（Debian / Ubuntu）
# ===========================================================================
do_install_deb() {
    local tar_name="docker-ce-repo-$dist_version.tar"
    info "下载仓库: $tar_name（若网络慢，可 --mirror 指定加速前缀）"
    download_and_verify "$tar_name"

    # ---------- 安装 apt 源 ----------
    $sh_c "install -d -m 0755 $REPO_DIR"
    $sh_c "tar -xf $tmpdir/$tar_name -C $REPO_DIR"
    $sh_c "install -d -m 0755 /etc/apt/keyrings"
    # 优先使用仓库包内置的 binary keyring（apt 的 signed-by 需要 binary 格式，
    # 且不依赖目标机是否装有 gpg）；缺失时才现场转换/兜底
    if [ -f "$REPO_DIR/keyring/docker-cn.gpg" ]; then
        $sh_c "install -m 0644 $REPO_DIR/keyring/docker-cn.gpg $KEYRING"
    elif command_exists gpg; then
        $sh_c "gpg --batch --dearmor -o $KEYRING $REPO_DIR/keyring/docker-ce-cn.asc"
    else
        $sh_c "cp $REPO_DIR/keyring/docker-ce-cn.asc $KEYRING"
    fi
    [ -s "$KEYRING" ] || die "仓库公钥安装失败（$KEYRING 为空）"
    info "已安装仓库公钥到 $KEYRING"

    # 备份移出 sources.list.d（apt 对非 .list 扩展名会告警），并清理历史残留备份
    $sh_c "rm -f /etc/apt/sources.list.d/docker-cn.list.bak.* 2>/dev/null || true"
    if [ -f "$SOURCE_FILE" ]; then
        $sh_c "cp $SOURCE_FILE /etc/apt/docker-cn.list.bak.$(date +%s)"
        info "已备份原 $SOURCE_FILE"
    fi
    # file: 源 —— 无第三方网络依赖，仓库内容来自已校验的本地文件
    $sh_c "echo 'deb [signed-by=$KEYRING] file:$REPO_DIR $dist_version stable' > $SOURCE_FILE"

    # ---------- 安装 Docker ----------
    $sh_c "apt-get -qq update" || die "apt-get update 失败"
    local pkgs="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-model-plugin"
    local apt_flags="-y -qq"

    if [ -n "$VERSION" ]; then
        info "查找版本 '$VERSION' ..."
        local ver_esc pkg_version cli_pkg_version
        ver_esc="$(printf '%s' "$VERSION" | sed 's/[.[\\*^$]/\\&/g')"
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
}

# ===========================================================================
# rpm 流程（CentOS / Rocky / RHEL / AlmaLinux / Fedora）
# ===========================================================================
do_install_rpm() {
    local tar_name="docker-ce-repo-rpm-$rpm_id.tar" names pkgs pinned hit n pm
    info "下载仓库: $tar_name（若网络慢，可 --mirror 指定加速前缀）"
    download_and_verify "$tar_name"

    # ---------- 安装 yum/dnf 源（file:// 本地仓库） ----------
    # 包管理器需在 repo 文件生成前确定：
    #   dnf（Rocky/RHEL 9+/Fedora）完整支持 gpgkey=file:// 的 repo_gpgcheck；
    #   yum 3.4（CentOS 7）无法从 file:// 加载 gpgkey（实测 "Gpg Keys not
    #   imported"），必须关闭 repo_gpgcheck，否则仓库被 yum 直接拒绝
    if command_exists dnf; then
        pm="dnf"
        repo_gpgcheck=1
    else
        pm="yum"
        repo_gpgcheck=0
    fi
    $sh_c "install -d -m 0755 $REPO_DIR"
    $sh_c "tar -xf $tmpdir/$tar_name -C $REPO_DIR"
    cat > "$tmpdir/docker-cn.repo" <<REPO
[docker-cn]
name=Docker CE (docker-install-cn)
baseurl=file://$REPO_DIR/Packages
enabled=1
gpgcheck=0
repo_gpgcheck=$repo_gpgcheck
gpgkey=file://$REPO_DIR/keyring/docker-cn.asc
REPO
    # 备份移出 yum.repos.d（dnf 对非 .repo 扩展名会告警），并清理历史残留备份
    $sh_c "rm -f /etc/yum.repos.d/docker-cn.repo.bak.* 2>/dev/null || true"
    if [ -f "$RPM_REPO_FILE" ]; then
        $sh_c "cp $RPM_REPO_FILE /etc/docker-cn.repo.bak.$(date +%s)"
        info "已备份原 $RPM_REPO_FILE"
    fi
    $sh_c "install -m 0644 $tmpdir/docker-cn.repo $RPM_REPO_FILE"
    $sh_c "rpm --import $REPO_DIR/keyring/docker-cn.asc 2>/dev/null || true"
    if [ "$repo_gpgcheck" = "1" ]; then
        info "已配置 $RPM_REPO_FILE（repo_gpgcheck=1 校验仓库签名）"
    else
        info "已配置 $RPM_REPO_FILE（yum 3.4 兼容模式，仓库签名校验已关闭）"
    fi

    # ---------- 安装 Docker ----------
    # 只安装仓库中实际存在的包（各发行版包集合略有差异）
    # 注意：ls 输出是换行分隔，必须转成空格，否则 case " $n " 匹配不到
    names="$($sh_c "ls $REPO_DIR/Packages/*.rpm 2>/dev/null | sed 's#.*/##; s/-[0-9].*//' | sort -u | tr '\n' ' '" 2>/dev/null || true)"
    pkgs=""
    for n in docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras docker-model-plugin; do
        case " $names " in
            *" $n "*) pkgs="$pkgs $n" ;;
        esac
    done
    [ -n "$pkgs" ] || die "仓库中未找到任何 docker 包（同步可能不完整）"

    if [ -n "$VERSION" ]; then
        info "查找版本 '$VERSION' ..."
        hit="$($sh_c "ls $REPO_DIR/Packages/docker-ce-${VERSION}* 2>/dev/null | head -1" || true)"
        if [ -z "$hit" ]; then
            echo "错误: 仓库中未找到 docker-ce 版本 '$VERSION'，可用版本:" >&2
            $sh_c "ls $REPO_DIR/Packages/ | grep '^docker-ce-[0-9]' | head -15" >&2 || true
            exit 1
        fi
        pinned=""
        for n in $pkgs; do
            case "$n" in
                docker-ce|docker-ce-cli) pinned="$pinned $n-${VERSION}*" ;;
                *) pinned="$pinned $n" ;;
            esac
        done
        pkgs="$pinned"
        info "安装 $pkgs"
    else
        info "安装最新稳定版: $pkgs"
    fi

    # file:// 仓库内容每次同步都会变，强制过期元数据缓存
    $sh_c "$pm clean expire-cache 2>/dev/null || true"
    $sh_c "$pm -y install $pkgs" || die "安装失败"

    if [ -f "$REPO_DIR/repo-version.txt" ]; then
        echo "----------------------------------------"
        echo "仓库同步信息（$REPO_DIR/repo-version.txt）:"
        cat "$REPO_DIR/repo-version.txt"
        echo "----------------------------------------"
    fi
}

# ===========================================================================
# 公共收尾：启动服务 / docker 组 / registry 镜像加速 / 汇总
# ===========================================================================
enable_docker_service() {
    if [ "$NO_AUTOSTART" = "1" ]; then
        info "已跳过自动启动（--no-autostart）"
        return
    fi
    if command_exists systemctl; then
        if $sh_c "systemctl enable --now docker 2>/dev/null"; then
            info "docker 服务已启用并启动"
        else
            warn "无法自动启动 docker 服务（可稍后手动 systemctl start docker）"
        fi
    else
        warn "未检测到 systemd，跳过自动启动"
    fi
}

add_to_docker_group() {
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        $sh_c "usermod -aG docker '$SUDO_USER'" 2>/dev/null || true
        info "已将用户 $SUDO_USER 加入 docker 组，重新登录后免 sudo 使用 docker"
    fi
}

# 确保基础工具齐全（极简系统 / 容器镜像可能缺 tar 等；已有则跳过）
ensure_basic_tools() {
    local missing=""
    for t in tar curl sha256sum sed awk sort tr grep; do
        command_exists "$t" || missing="$missing $t"
    done
    [ -z "$missing" ] && return 0
    info "检测到系统缺少基础工具:$missing，自动安装中..."
    case "$PKG_KIND" in
        deb)
            $sh_c "DEBIAN_FRONTEND=noninteractive apt-get -y -qq update >/dev/null 2>&1 || true"
            $sh_c "DEBIAN_FRONTEND=noninteractive apt-get -y -qq install $missing"
            ;;
        rpm)
            if command_exists dnf; then
                $sh_c "dnf -y -q install $missing"
            else
                $sh_c "yum -y -q install $missing"
            fi
            ;;
    esac
    for t in $missing; do
        command_exists "$t" || die "基础工具 $t 安装失败"
    done
    info "基础工具已就绪"
}

configure_registry_mirrors() {
    local mirrors daemon_json mirrors_json m
    if [ "$NO_REGISTRY_MIRROR" = "1" ]; then
        info "已跳过 registry 镜像加速（--no-registry-mirror）"
        return
    fi
    mirrors="$EXTRA_MIRRORS"
    [ -n "$REGISTRY_MIRRORS" ] && mirrors="$mirrors $(printf '%s' "$REGISTRY_MIRRORS" | tr ',' ' ')"
    if is_china_network; then
        # 国内网络：默认加速站 + 用户指定
        mirrors="$DEFAULT_REGISTRY_MIRRORS $mirrors"
        info "检测到国内网络，配置 registry 镜像加速"
    elif [ -n "$mirrors" ]; then
        # 海外网络：仅用户显式指定
        info "海外网络：仅使用用户指定的 registry 镜像"
    else
        # 海外网络：直连 Docker Hub 更快，默认不配国内加速站
        info "海外网络：跳过 registry 镜像加速（直连 Docker Hub 更快，可用 --registry-mirror 指定）"
        if [ -f /etc/docker/daemon.json ] && grep -q "docker.1ms.run\|docker.m.daocloud.io\|docker.1panel.live" /etc/docker/daemon.json 2>/dev/null; then
            warn "检测到 /etc/docker/daemon.json 残留国内加速镜像，可手动编辑移除（或备份文件见 /etc/docker/）"
        fi
        return
    fi
    mirrors="$(printf '%s\n' $mirrors | awk 'NF' | sort -u | tr '\n' ' ')"
    if [ -n "$mirrors" ]; then
        info "配置 registry 镜像加速: $mirrors"
        $sh_c "install -d -m 0755 /etc/docker"
        daemon_json="/etc/docker/daemon.json"
        [ -f "$daemon_json" ] && $sh_c "cp $daemon_json $daemon_json.bak.$(date +%s)" && info "已备份原 $daemon_json"
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
}

print_summary() {
    echo
    echo "================================================================================="
    echo "  Docker 安装完成！"
    if command_exists docker; then
        set +e
        docker version 2>/dev/null
        set -e
    fi
    echo
    echo "  - compose:  $(docker compose version 2>/dev/null | head -1 || echo '未安装')"
    echo "  - buildx:   $(docker buildx version 2>/dev/null | head -1 || echo '未安装')"
    echo "  - 仓库:  $PROJECT (tag: $TAG)"
    if [ "$PKG_KIND" = "deb" ]; then
        echo "  - 发行版: ${lsb_dist} ${dist_version} / ${arch}"
    else
        echo "  - 发行版: ${lsb_dist} ${ver_id} / ${arch}（仓库: $rpm_id）"
    fi
    echo "  - 提示:  非 root 用户需重新登录后生效 docker 组权限"
    echo "  - 加速:  /etc/docker/daemon.json 中的 registry-mirrors 可随时增删"
    echo "================================================================================="
}

# ----------------------------- 已安装检查 -----------------------------
# 已安装且未加 --force：直接显示版本/状态后退出，避免重复下载与重装
if [ "$FORCE" != "1" ] && command_exists docker; then
    echo
    echo "========================================================================"
    info "Docker 已安装: $(docker --version 2>/dev/null || docker -v 2>/dev/null || echo 未知版本)"
    if command_exists systemctl && systemctl is-active docker >/dev/null 2>&1; then
        info "docker 服务状态: 运行中"
    elif command_exists systemctl; then
        warn "docker 服务状态: 未运行（可 systemctl start docker）"
    fi
    echo "如需重新安装或升级到仓库最新版本，请加 --force 参数重新执行本脚本"
    echo "========================================================================"
    echo
    exit 0
fi

# 确保基础工具齐全（极简系统缺 tar 等会导致解压失败）
ensure_basic_tools

# ----------------------------- 执行 -----------------------------
if [ "$PKG_KIND" = "deb" ]; then
    do_install_deb
else
    do_install_rpm
fi
enable_docker_service
add_to_docker_group
configure_registry_mirrors
print_summary
