# Docker_Private_Source · 国内一键安装 Docker

[![sync-docker-ce](https://github.com/MinimaxFlora/Docker_Private_Source/actions/workflows/sync.yml/badge.svg)](https://github.com/MinimaxFlora/Docker_Private_Source/actions/workflows/sync.yml)

[English](./README_EN.md)

面向国内网络的 Docker Engine 一键安装方案：GitHub Actions 每天定时同步官方
[docker-ce](https://download.docker.com) apt/yum 仓库，用**本项目的 GPG 私钥重新签名**后托管在
GitHub Release，一键脚本经 **ghproxy 等加速通道**下载并在本地配置 apt/yum 源安装。

不需要修改系统 DNS、不需要第三方镜像站保持可用、不依赖 get.docker.com 连通性。

## 快速开始

```bash
# Debian / Ubuntu (amd64 / arm64)，默认安装最新稳定版
sh -c "$(curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh)"

# Rocky 9/10、CentOS 7/9/10、RHEL 9/10、AlmaLinux 9/10、Fedora 43/44 (x86_64 / aarch64)
# 同一脚本自动识别，无需额外参数
```

GitHub 直连不顺畅时，可从 jsDelivr CDN 拉取脚本：

```bash
sh -c "$(curl -fsSL https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_Source@master/install.sh)"
```

脚本自动完成：

1. 经加速通道下载仓库包（`docker-ce-repo-<codename>.tar` / `docker-ce-repo-rpm-<id>.tar`）并校验 SHA256
2. Debian/Ubuntu 配置本地 `file:` apt 源（`/opt/docker-ce-cn`），安装本项目公钥；
   Rocky/CentOS/RHEL/Alma/Fedora 配置本地 `file://` yum/dnf 源（`repo_gpgcheck=1` 校验仓库签名）
3. 安装 docker-ce 全家桶：`docker-ce`、`docker-ce-cli`、`containerd.io`、
   `docker-buildx-plugin`、`docker-compose-plugin`、`docker-ce-rootless-extras`、`docker-model-plugin`
   （各发行版缺失的包自动跳过）
4. `systemctl enable --now docker` 自动启动，当前用户加入 `docker` 组
5. 自动配置 `/etc/docker/daemon.json` 的 `registry-mirrors`（docker pull 镜像加速）

## 参数

| 参数 | 说明 |
| --- | --- |
| `--version <VERSION>` | 指定版本，如 `--version 29.7` 或 `--version 29.7.2` |
| `--mirror <URL>` | 指定 GitHub 加速前缀（覆盖默认；默认自动检测网络：国内优先 `gh-proxy.kejizero.xyz`，海外直连） |
| `--registry-mirror <URL>` | 追加一个 docker 镜像加速地址（可重复） |
| `--no-registry-mirror` | 跳过 registry 镜像加速配置 |
| `--no-autostart` | 不自动启动 docker 服务 |
| `--dry-run` | 只打印将要执行的步骤 |
| `--help` | 帮助 |

环境变量与参数等效：`VERSION`、`DOWNLOAD_MIRROR`、`CHINA_MIRROR`（国内默认加速站，默认
`https://gh-proxy.kejizero.xyz`）、`REGISTRY_MIRRORS`（逗号分隔）、`NO_AUTOSTART`、
`NO_REGISTRY_MIRROR`、`PROJECT`、`TAG`。

> 网络自动检测：脚本会先探测境外可达性（google / baidu），判定为国内网络时自动优先使用
> `gh-proxy.kejizero.xyz` 加速站下载仓库包，其余镜像兜底；海外网络则直连 GitHub。
> 也可用 `--mirror` 或环境变量 `CHINA_MIRROR` 指定你自己的加速站。

示例：

```bash
# 指定版本安装
curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh -o install.sh
sudo bash install.sh --version 29.7

# 指定加速前缀 + 追加镜像加速
sudo bash install.sh --mirror https://ghfast.top --registry-mirror https://docker.m.daocloud.io
```

## 支持的发行版与架构

| 发行版 | 版本 | 仓库 | 架构 |
| --- | --- | --- | --- |
| Debian 13 | trixie | deb | amd64, arm64 |
| Debian 12 | bookworm | deb | amd64, arm64 |
| Debian 11 | bullseye | deb | amd64, arm64 |
| Ubuntu 24.04 | noble | deb | amd64, arm64 |
| Ubuntu 22.04 | jammy | deb | amd64, arm64 |
| Ubuntu 20.04 | focal | deb | amd64, arm64 |
| Rocky 10 / CentOS 10 / RHEL 10 / Alma 10 | 10 | el10 | x86_64, aarch64 |
| Rocky 9 / CentOS 9 / RHEL 9 / Alma 9 | 9 | el9 | x86_64, aarch64 |
| CentOS 7（含老机器） | 7 | el7 | x86_64, aarch64 |
| Fedora 44 / 43 | 44 / 43 | fedora-44 / fedora-43 | x86_64, aarch64 |

> 说明：Docker 官方并未在 rocky/rhel 目录发布 docker-ce（rocky 目录只有插件包），
> el 系仓库统一从官方 centos 目录同步（`-1.el9` / `-1.el10` / `-1.el7` 均为 el 系通用包），
> Rocky / CentOS / RHEL / AlmaLinux 用户直接安装即可。
> Fedora 每 6 个月发布新版本，新版本上线后需更新同步矩阵（`.github/workflows/sync.yml` 与
> `install.sh` 的版本白名单）。

## 工作原理

```
┌─────────────────────────── GitHub Actions（每天 + 手动触发）──────────────────────────┐
│  download.docker.com ──► 下载 docker-ce 家族 .deb/.rpm（每包保留最近 3 个版本）          │
│       │                    deb: 6 个代号 × amd64/arm64                                 │
│       │                    rpm: el7/el9/el10 + fedora-44/43 × x86_64/aarch64          │
│       ▼                                                                               │
│  deb: apt-ftparchive 重新生成 Packages 索引 + Release                                 │
│  rpm: createrepo_c 重新生成 repodata（repomd.xml）                                     │
│       │                    ▲                                                          │
│       ▼                    └── 本项目 GPG 私钥签名 InRelease / repomd.xml.asc          │
│  打包 docker-ce-repo-<codename>.tar / docker-ce-repo-rpm-<id>.tar + SHA256             │
│       │                                                                               │
│       ▼                                                                               │
│  GitHub Release（固定 tag: latest，每次覆盖上传）── ghproxy 等镜像只代理 release 下载 ✓ │
└───────────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼  国内机器
   install.sh ──► 加速下载 + SHA256 校验 ──► 本地 file:/file:// 源（本项目 GPG 公钥）
        └──► apt-get / dnf install docker-ce ... ──► 启动服务 / docker 组 / registry 加速
```

安全模型：安装包内容与官方 docker-ce 仓库完全一致（不重新打包 .deb/.rpm），apt 通过
`Release/InRelease` 的 GPG 签名（本项目密钥）验证仓库完整性，dnf/yum 通过 `repomd.xml.asc`
验证，下载过程另加 SHA256 双重校验。

## 自建部署（fork 后）

1. **Fork 本仓库**（默认分支 `master`，改 `install.sh` 顶部 `PROJECT="你的/仓库"`）
2. **生成本项目签名密钥**（本机执行一次）：

   ```bash
   ./generate-key.sh        # 生成 public-key.asc（提交）与 gpg-private.key（保密）
   ```

3. **配置 GitHub Secrets**（仓库 → Settings → Secrets and variables → Actions）：

   | Secret | 值 |
   | --- | --- |
   | `GPG_PRIVATE_KEY` | `gpg-private.key` 的完整内容 |
   | `GPG_PASSPHRASE` | 密钥口令 |

4. **推送 `public-key.asc` 后**手动触发一次工作流
   （Actions → sync-docker-ce → Run workflow）生成首批仓库资产
5. 之后每天 02:23 UTC 自动同步；也可以在 docker 发新版后手动触发

## 常见问题

- **apt 报 `InRelease` 校验失败 / dnf 报 `repomd.xml` 签名校验失败**：仓库签名密钥与公钥不匹配。确认
  Secrets 中 `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` 与仓库内 `public-key.asc` 出自同一次生成。
- **下载慢 / 失败**：`--mirror https://你的加速前缀` 手动指定；加速站列表见脚本内
  `DEFAULT_MIRRORS`。
- **想装旧版本**：仓库保留每包最近 3 个版本，`--version` 指定即可
  （deb 如 `--version 27.3`，rpm 如 `--version 29.7`）。
- **registry 镜像失效**：镜像加速站时效性强，用 `--registry-mirror` 追加或直接编辑
  `/etc/docker/daemon.json` 后 `systemctl restart docker`。
- **dnf 报依赖解析失败**：rpm 安装时 dnf 需要系统自带 base/AppStream 源可用来解析依赖
  （containerd 等依赖项），请确保机器原有 yum/dnf 源配置正常。
- **CentOS 7** 已 EOL，但国内存量机器多，el7 仓库持续同步（docker-ce 官方仍发布 el7 包）。

## License

[MIT](./LICENSE)
