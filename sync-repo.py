#!/usr/bin/env python3
"""
docker-ce 仓库同步与重签名脚本（在 GitHub Actions 中运行）

deb 模式（环境变量 CODENAME）:
1. 从 download.docker.com 拉取指定 codename 的 amd64/arm64 官方包索引
2. 筛选 docker-ce 家族包，每包保留最新 KEEP 个版本，下载 .deb 到 pool/
3. 用 apt-ftparchive 重新生成 dists/<codename>/stable/binary-<arch>/{Packages,Packages.gz}
4. 生成 dists/<codename>/Release，并用本项目 GPG 私钥签名（InRelease / Release.gpg）
5. 打包 docker-ce-repo-<codename>.tar + .sha256 校验文件

rpm 模式（环境变量 RPM_DISTRO / RPM_VERSION / RPM_ID）:
1. 解析 download.docker.com 的 rpm 仓库 repomd.xml → primary.xml（zstd 解压）
2. 筛选 docker-ce 家族包，每包保留最新 KEEP 个版本，下载 .rpm 到 <id>/Packages/
3. 用 createrepo_c 生成 repodata，GPG 签名 repomd.xml（repomd.xml.asc）
4. 打包 docker-ce-repo-rpm-<id>.tar + .sha256 校验文件

环境变量:
  CODENAME          发行版代号（deb 模式必填，如 bookworm / noble）
  RPM_DISTRO        rpm 上游发行版（centos / fedora）
  RPM_VERSION       rpm 上游版本（7 / 9 / 10 / 44 / 43）
  RPM_ID            目标标识（el7 / el9 / el10 / fedora-44 / fedora-43）
  KEEP_VERSIONS     每个包保留的版本数（默认 3）
  GPG_PASSPHRASE    签名密钥口令（密钥无口令时留空）
  GPG_KEY_ID        签名密钥 ID（默认自动探测第一个私钥）
  GITHUB_REPOSITORY 用于 Release 元数据（如 MinimaxFlora/Docker_Private_source）
"""

import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

UPSTREAM = "https://download.docker.com/linux"
PACKAGES = [
    "docker-ce",
    "docker-ce-cli",
    "containerd.io",
    "docker-buildx-plugin",
    "docker-compose-plugin",
    "docker-ce-rootless-extras",
    "docker-model-plugin",
]
ARCHS = ["amd64", "arm64"]
RPM_ARCHS = ["x86_64", "aarch64"]
# codename -> 上游发行版
DISTRO = {
    "trixie": "debian", "bookworm": "debian", "bullseye": "debian",
    "noble": "ubuntu", "jammy": "ubuntu", "focal": "ubuntu",
}
# rpm 常用命名空间
NS_REPO = "{http://linux.duke.edu/metadata/repo}"
NS_COMMON = "{http://linux.duke.edu/metadata/common}"
NS_RPM = "{http://linux.duke.edu/metadata/rpm}"
KEEP = int(os.environ.get("KEEP_VERSIONS", "3"))
UA = "docker-ce-cn-sync/1.0"


def log(msg):
    print(f"[sync] {msg}", flush=True)


def fetch(url, retries=3):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except Exception as e:
            if i == retries - 1:
                raise
            log(f"下载失败({e})，重试 {i + 1}/{retries}: {url}")
            time.sleep(3)


def parse_packages(data):
    """解析 apt Packages 文本，返回记录 dict 列表"""
    recs = []
    for block in data.decode("utf-8", "replace").split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if not line or line[0] in " \t" or ":" not in line:
                continue
            k, _, v = line.partition(":")
            fields[k] = v.strip()
        if fields.get("Package"):
            recs.append(fields)
    return recs


def sort_versions(versions):
    """按 dpkg 版本规则降序排序（epoch / ~ 语义正确）"""
    ordered = []
    for v in versions:
        pos = len(ordered)
        for i, o in enumerate(ordered):
            r = subprocess.run(["dpkg", "--compare-versions", v, "gt", o], capture_output=True)
            if r.returncode == 0:  # v > o，插到 o 前面
                pos = i
                break
        ordered.insert(pos, v)
    return ordered


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def detect_keyid():
    out = subprocess.run(
        ["gpg", "--batch", "--list-secret-keys", "--with-colons"],
        capture_output=True, text=True,
    ).stdout
    for line in out.splitlines():
        if line.startswith("sec:"):
            return line.split(":")[4]
    return None


def gpg_base(keyid):
    base = ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
            "--local-user", keyid]
    if os.environ.get("GPG_PASSPHRASE"):
        base += ["--passphrase", os.environ["GPG_PASSPHRASE"]]
    return base


# ---------------------------------------------------------------------------
# rpm 版本比较（纯 Python，语义对齐 rpm/dpkg：~ 最低、字母 < 数字、先耗尽者小）
# ---------------------------------------------------------------------------
_RANK = {"~": 0, None: 1, "a": 2, "n": 3}


def _tokens(s):
    """把版本串切分为 token 序列：('~',) / ('a', str) / ('n', int)"""
    toks = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "~":
            toks.append(("~",))
            i += 1
        elif c in ".-":
            i += 1
        elif c.isdigit():
            j = i
            while j < n and s[j].isdigit():
                j += 1
            toks.append(("n", int(s[i:j])))
            i = j
        else:
            j = i
            while j < n and s[j].isalpha():
                j += 1
            toks.append(("a", s[i:j]))
            i = j
    return toks


def _cmp_tokseq(a, b):
    for i in range(max(len(a), len(b))):
        ta = a[i] if i < len(a) else None
        tb = b[i] if i < len(b) else None
        ra, rb = _RANK[ta[0] if ta else None], _RANK[tb[0] if tb else None]
        if ra != rb:
            return -1 if ra < rb else 1
        if ta is None or ta[0] == "~":
            continue
        if ta[1] != tb[1]:
            return -1 if ta[1] < tb[1] else 1
    return 0


def rpm_verkey(epoch, ver, rel):
    """返回可比较的元组 (epoch, 上游 token, release token)"""
    return (int(epoch or "0"), _tokens(ver), _tokens(rel))


def cmp_rpm_versions(a, b):
    """a、b 为 rpm_verkey 元组，返回 -1/0/1（a < b 为 -1）"""
    if a[0] != b[0]:
        return -1 if a[0] < b[0] else 1
    c = _cmp_tokseq(a[1], b[1])
    if c:
        return c
    return _cmp_tokseq(a[2], b[2])


def rpm_repomd(base):
    """获取 rpm 仓库 primary 解析树。base 形如 .../linux/centos/9/x86_64/stable"""
    repomd = fetch(f"{base}/repodata/repomd.xml")
    root = ET.fromstring(repomd)
    href = root.find(f"{NS_REPO}data[@type='primary']/{NS_REPO}location").attrib["href"]
    primary = fetch(f"{base}/{href}")
    # primary 的压缩格式由扩展名决定：新仓库为 .zst，CentOS 7 等老仓库为 .gz
    if href.endswith(".zst"):
        try:
            import zstandard
        except ImportError:
            raise SystemExit("缺少 zstandard 库（rpm 模式需要），请先: pip install zstandard")
        # 流式解压：帧头可能不含 content size，不能用 decompress() 直接方法
        dobj = zstandard.ZstdDecompressor().decompressobj()
        chunks = [dobj.decompress(primary)]
        while not dobj.eof:
            chunks.append(dobj.decompress(b""))
        xml = b"".join(chunks)
    elif href.endswith(".gz"):
        xml = gzip.decompress(primary)
    else:
        xml = primary
    return ET.fromstring(xml)


def parse_rpm_packages(root):
    """解析 primary.xml 的 package 列表"""
    out = []
    for pkg in root.findall(f"{NS_COMMON}package"):
        name_el = pkg.find(f"{NS_COMMON}name")
        ver_el = pkg.find(f"{NS_COMMON}version")
        loc_el = pkg.find(f"{NS_COMMON}location")
        if name_el is None or ver_el is None or loc_el is None:
            continue
        chk = pkg.find(f"{NS_COMMON}checksum")
        arch_el = pkg.find(f"{NS_COMMON}arch")
        out.append({
            "name": name_el.text,
            "epoch": ver_el.attrib.get("epoch", "0"),
            "ver": ver_el.attrib.get("ver", ""),
            "rel": ver_el.attrib.get("rel", ""),
            "loc": loc_el.attrib.get("href", ""),
            "sha256": chk.text if chk is not None and chk.attrib.get("type") == "sha256" else "",
            "arch": arch_el.text if arch_el is not None else "",
        })
    return out


# ---------------------------------------------------------------------------
# deb 模式
# ---------------------------------------------------------------------------
def sync_deb():
    cn = os.environ.get("CODENAME", "").strip()
    if cn not in DISTRO:
        raise SystemExit(f"CODENAME 无效: {cn!r}，支持: {', '.join(DISTRO)}")
    distro = DISTRO[cn]
    origin = os.environ.get("GITHUB_REPOSITORY", "docker-ce-cn")
    root = os.path.abspath(".")
    pool_root = os.path.join(root, "pool", "stable")
    dists_dir = os.path.join(root, "dists", cn, "stable")
    latest = {}  # latest[arch][pkg] = 最新版本

    downloaded = skipped = 0
    for arch in ARCHS:
        index_url = f"{UPSTREAM}/{distro}/dists/{cn}/stable/binary-{arch}/Packages.gz"
        log(f"拉取索引: {index_url}")
        recs = parse_packages(gzip.decompress(fetch(index_url)))
        wanted = {p: [] for p in PACKAGES}
        for r in recs:
            if r.get("Package") in wanted and r.get("Filename") and r.get("SHA256"):
                wanted[r["Package"]].append(r)
        arch_dir = os.path.join(pool_root, arch)
        os.makedirs(arch_dir, exist_ok=True)
        latest[arch] = {}
        for pkg in PACKAGES:
            versions = sort_versions({r["Version"] for r in wanted[pkg]})
            latest[arch][pkg] = versions[0] if versions else ""
            for ver in versions[:KEEP]:
                rec = next(r for r in wanted[pkg] if r["Version"] == ver)
                fname = os.path.basename(rec["Filename"])
                dst = os.path.join(arch_dir, fname)
                if os.path.exists(dst) and sha256_file(dst) == rec["SHA256"]:
                    skipped += 1
                    continue
                log(f"下载 {pkg} {ver} [{arch}]")
                # 官方 Filename 形如 dists/<codename>/pool/stable/...，相对 <upstream>/<distro>/
                data = fetch(f"{UPSTREAM}/{distro}/{rec['Filename']}")
                if hashlib.sha256(data).hexdigest() != rec["SHA256"]:
                    raise SystemExit(f"SHA256 校验失败: {fname}")
                with open(dst, "wb") as f:
                    f.write(data)
                downloaded += 1
    log(f"下载 {downloaded} 个新包，跳过 {skipped} 个已存在")

    # ---------- 生成包索引 ----------
    for arch in ARCHS:
        pkg_index = os.path.join(dists_dir, f"binary-{arch}", "Packages")
        os.makedirs(os.path.dirname(pkg_index), exist_ok=True)
        with open(pkg_index, "w", encoding="utf-8") as f:
            subprocess.run(["apt-ftparchive", "packages", os.path.join(pool_root, arch)],
                           stdout=f, check=True)
        with open(pkg_index, "rb") as fi, gzip.open(pkg_index + ".gz", "wb") as fo:
            fo.write(fi.read())
        log(f"生成索引: {pkg_index}.gz")

    # ---------- 生成 Release ----------
    date = time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime())
    valid_until = time.strftime("%a, %d %b %Y %H:%M:%S UTC", time.gmtime(time.time() + 14 * 86400))
    release_cmd = [
        "apt-ftparchive",
        "-o", f"APT::FTPArchive::Release::Origin={origin}",
        "-o", "APT::FTPArchive::Release::Label=docker-ce-cn",
        "-o", f"APT::FTPArchive::Release::Suite={cn}",
        "-o", f"APT::FTPArchive::Release::Codename={cn}",
        "-o", "APT::FTPArchive::Release::Architectures=" + " ".join(ARCHS),
        "-o", "APT::FTPArchive::Release::Components=stable",
        "-o", f"APT::FTPArchive::Release::Date={date}",
        "-o", f"APT::FTPArchive::Release::Valid-Until={valid_until}",
        "release", os.path.join("dists", cn),
    ]
    release_file = os.path.join("dists", cn, "Release")
    with open(release_file, "w", encoding="utf-8") as f:
        subprocess.run(release_cmd, stdout=f, check=True)
    log(f"生成 Release: {release_file}")

    # ---------- GPG 签名 ----------
    keyid = os.environ.get("GPG_KEY_ID") or detect_keyid()
    if keyid:
        gpg_base_cmd = gpg_base(keyid)
        subprocess.run(gpg_base_cmd + ["--clearsign", "-o", os.path.join("dists", cn, "InRelease"),
                                       os.path.join("dists", cn, "Release")], check=True)
        subprocess.run(gpg_base_cmd + ["-abs", "-o", os.path.join("dists", cn, "Release.gpg"),
                                       os.path.join("dists", cn, "Release")], check=True)
        log(f"已用 {keyid} 签名 InRelease / Release.gpg")
    else:
        log("!! 未找到 GPG 私钥，跳过签名（仓库将无法通过 apt 校验）")

    # ---------- 附带文件 ----------
    keyring_dir = os.path.join(root, "keyring")
    os.makedirs(keyring_dir, exist_ok=True)
    if os.path.exists("public-key.asc"):
        shutil.copy("public-key.asc", os.path.join(keyring_dir, "docker-ce-cn.asc"))
        # 同时生成 binary keyring：apt 的 signed-by 需要 binary 格式，
        # 且目标机不一定装有 gpg，因此直接打包成品
        subprocess.run(["gpg", "--batch", "--dearmor", "-o",
                        os.path.join(keyring_dir, "docker-cn.gpg"),
                        "public-key.asc"], check=True)
        log("已生成 binary keyring: keyring/docker-cn.gpg")
    with open("repo-version.txt", "w", encoding="utf-8") as f:
        f.write(f"codename={cn}\n")
        f.write(f"synced={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        for arch in ARCHS:
            f.write(f"[{arch}]\n")
            for pkg in PACKAGES:
                f.write(f"{pkg}={latest[arch][pkg]}\n")

    # ---------- 打包 ----------
    tar_name = f"docker-ce-repo-{cn}.tar"
    subprocess.run(["tar", "-cf", tar_name, "dists", "pool", "keyring", "repo-version.txt"],
                   check=True)
    with open(tar_name + ".sha256", "w", encoding="utf-8") as f:
        f.write(f"{sha256_file(tar_name)}  {tar_name}\n")
    size_mb = os.path.getsize(tar_name) / 1048576
    log(f"完成: {tar_name} ({size_mb:.1f} MB)")


# ---------------------------------------------------------------------------
# rpm 模式
# ---------------------------------------------------------------------------
def sync_rpm():
    distro = os.environ.get("RPM_DISTRO", "").strip()
    version = os.environ.get("RPM_VERSION", "").strip()
    rid = os.environ.get("RPM_ID", "").strip()
    if not (distro and version and rid):
        raise SystemExit("rpm 模式需要 RPM_DISTRO / RPM_VERSION / RPM_ID")
    if distro not in ("centos", "fedora"):
        raise SystemExit(f"RPM_DISTRO 无效: {distro!r}，支持: centos / fedora")

    root = os.path.abspath(".")
    repo_root = os.path.join(root, rid)            # <id>/Packages/*.rpm + repodata/
    pkg_dir = os.path.join(repo_root, "Packages")
    os.makedirs(pkg_dir, exist_ok=True)
    latest = {}
    downloaded = skipped = 0
    ok_arches = 0

    for arch in RPM_ARCHS:
        base = f"{UPSTREAM}/{distro}/{version}/{arch}/stable"
        try:
            log(f"拉取 rpm 索引: {base}/repodata/repomd.xml")
            proot = rpm_repomd(base)
        except Exception as e:
            log(f"!! {arch} 索引拉取失败（跳过该架构）: {e}")
            continue
        pkgs = parse_rpm_packages(proot)
        wanted = {p: [] for p in PACKAGES}
        for r in pkgs:
            if r["name"] in wanted and r["loc"] and r["sha256"] and r["arch"] == arch:
                wanted[r["name"]].append(r)
        latest[arch] = {}
        for name in PACKAGES:
            cands = sorted(wanted[name],
                           key=lambda r: rpm_verkey(r["epoch"], r["ver"], r["rel"]),
                           reverse=True)
            latest[arch][name] = f"{cands[0]['ver']}-{cands[0]['rel']}" if cands else ""
            for rec in cands[:KEEP]:
                fname = os.path.basename(rec["loc"])
                dst = os.path.join(pkg_dir, fname)
                if os.path.exists(dst) and sha256_file(dst) == rec["sha256"]:
                    skipped += 1
                    continue
                log(f"下载 {name} {rec['ver']}-{rec['rel']} [{arch}]")
                data = fetch(f"{base}/{rec['loc']}")
                if hashlib.sha256(data).hexdigest() != rec["sha256"]:
                    raise SystemExit(f"SHA256 校验失败: {fname}")
                with open(dst, "wb") as f:
                    f.write(data)
                downloaded += 1
        ok_arches += 1
    log(f"下载 {downloaded} 个新包，跳过 {skipped} 个已存在")
    if not ok_arches:
        raise SystemExit("所有架构索引均拉取失败，请检查 RPM_DISTRO/RPM_VERSION 是否正确")

    # ---------- 生成 repodata ----------
    subprocess.run(["createrepo_c", pkg_dir], check=True)
    repomd = os.path.join(pkg_dir, "repodata", "repomd.xml")
    if not os.path.exists(repomd):
        raise SystemExit("createrepo_c 未生成 repomd.xml")
    log(f"生成 repodata: {pkg_dir}/repodata")

    # ---------- 签名 repomd.xml（dnf repo_gpgcheck 校验） ----------
    keyid = os.environ.get("GPG_KEY_ID") or detect_keyid()
    if keyid:
        subprocess.run(gpg_base(keyid) + ["--detach-sign", "--armor",
                                          "-o", repomd + ".asc", repomd], check=True)
        log(f"已用 {keyid} 签名 repomd.xml")
    else:
        log("!! 未找到 GPG 私钥，跳过签名（仓库将无法通过 dnf 校验）")

    # ---------- 附带文件 ----------
    keyring_dir = os.path.join(repo_root, "keyring")
    os.makedirs(keyring_dir, exist_ok=True)
    if os.path.exists("public-key.asc"):
        # rpm 的 gpgkey= 支持 armored 公钥
        shutil.copy("public-key.asc", os.path.join(keyring_dir, "docker-cn.asc"))
        log("已复制公钥: keyring/docker-cn.asc")
    with open(os.path.join(repo_root, "repo-version.txt"), "w", encoding="utf-8") as f:
        f.write(f"id={rid}\n")
        f.write(f"source={distro}/{version}\n")
        f.write(f"synced={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        for arch in latest:
            f.write(f"[{arch}]\n")
            for pkg in PACKAGES:
                f.write(f"{pkg}={latest[arch][pkg]}\n")

    # ---------- 打包（顶层为 Packages/ repodata/ keyring/ repo-version.txt） ----------
    tar_name = f"docker-ce-repo-rpm-{rid}.tar"
    subprocess.run(["tar", "-cf", tar_name, "-C", repo_root,
                    "Packages", "keyring", "repo-version.txt"], check=True)
    with open(tar_name + ".sha256", "w", encoding="utf-8") as f:
        f.write(f"{sha256_file(tar_name)}  {tar_name}\n")
    size_mb = os.path.getsize(tar_name) / 1048576
    log(f"完成: {tar_name} ({size_mb:.1f} MB)")


def main():
    if os.environ.get("CODENAME"):
        sync_deb()
    elif os.environ.get("RPM_DISTRO"):
        sync_rpm()
    else:
        raise SystemExit("请设置 CODENAME（deb 模式）或 RPM_DISTRO/RPM_VERSION/RPM_ID（rpm 模式）")


if __name__ == "__main__":
    main()
