#!/usr/bin/env python3
"""
docker-ce 仓库同步与重签名脚本（在 GitHub Actions 中运行）

流程：
1. 从 download.docker.com 拉取指定 codename 的 amd64/arm64 官方包索引
2. 筛选 docker-ce 家族包，每包保留最新 KEEP 个版本，下载 .deb 到 pool/
3. 用 apt-ftparchive 重新生成 dists/<codename>/stable/binary-<arch>/{Packages,Packages.gz}
4. 生成 dists/<codename>/Release，并用本项目 GPG 私钥签名（InRelease / Release.gpg）
5. 打包 docker-ce-repo-<codename>.tar + .sha256 校验文件

环境变量:
  CODENAME          发行版代号（必填，如 bookworm / noble）
  KEEP_VERSIONS     每个包保留的版本数（默认 3）
  GPG_PASSPHRASE    签名密钥口令（密钥无口令时留空）
  GPG_KEY_ID        签名密钥 ID（默认自动探测第一个私钥）
  GITHUB_REPOSITORY 用于 Release 元数据（如 MinimaxFlora/docker-install-cn）
"""

import gzip
import hashlib
import os
import shutil
import subprocess
import sys
import time
import urllib.request

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
# codename -> 上游发行版
DISTRO = {
    "trixie": "debian", "bookworm": "debian", "bullseye": "debian",
    "noble": "ubuntu", "jammy": "ubuntu", "focal": "ubuntu",
}
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


def main():
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
        with open(pkg_index, "rb") as fi, gzip.open(pkg_index + ".gz", "wb", mtime=0) as fo:
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
        gpg_base = ["gpg", "--batch", "--yes", "--pinentry-mode", "loopback",
                    "--local-user", keyid]
        if os.environ.get("GPG_PASSPHRASE"):
            gpg_base += ["--passphrase", os.environ["GPG_PASSPHRASE"]]
        subprocess.run(gpg_base + ["--clearsign", "-o", os.path.join("dists", cn, "InRelease"),
                                   os.path.join("dists", cn, "Release")], check=True)
        subprocess.run(gpg_base + ["-abs", "-o", os.path.join("dists", cn, "Release.gpg"),
                                   os.path.join("dists", cn, "Release")], check=True)
        log(f"已用 {keyid} 签名 InRelease / Release.gpg")
    else:
        log("!! 未找到 GPG 私钥，跳过签名（仓库将无法通过 apt 校验）")

    # ---------- 附带文件 ----------
    keyring_dir = os.path.join(root, "keyring")
    os.makedirs(keyring_dir, exist_ok=True)
    if os.path.exists("public-key.asc"):
        shutil.copy("public-key.asc", os.path.join(keyring_dir, "docker-ce-cn.asc"))
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


if __name__ == "__main__":
    main()
