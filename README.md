# Docker_Private_source · 国内一键安装 Docker

[![sync-docker-ce](https://github.com/MinimaxFlora/Docker_Private_source/actions/workflows/sync.yml/badge.svg)](https://github.com/MinimaxFlora/Docker_Private_source/actions/workflows/sync.yml)

[English](./README_EN.md)

面向国内网络的 Docker Engine 一键安装方案：GitHub Actions 定时同步官方
[docker-ce](https://download.docker.com) apt 仓库，用**本项目的 GPG 私钥重新签名**后托管在
GitHub Release，一键脚本经 **ghproxy 等加速通道**下载并在本地配置 apt 源安装。

不需要修改系统 DNS、不需要第三方镜像站保持可用、不依赖 get.docker.com 连通性。

## 快速开始

```bash
# Debian / Ubuntu (amd64 / arm64)，默认安装最新稳定版
sh -c "$(curl -fsSL https://github.com/MinimaxFlora/Docker_Private_source/raw/refs/heads/master/install.sh)"
```

GitHub 直连不顺畅时，可从 jsDelivr CDN 拉取脚本：

```bash
sh -c "$(curl -fsSL https://testingcf.jsdelivr.net/gh/MinimaxFlora/Docker_Private_source@master/install.sh)"
```

脚本自动完成：

1. 经加速通道下载仓库包（`docker-ce-repo-<codename>.tar`）并校验 SHA256
2. 配置本地 `file:` apt 源（`/opt/docker-ce-cn`），安装本项目公钥
3. 安装 docker-ce 全家桶：`docker-ce`、`docker-ce-cli`、`containerd.io`、
   `docker-buildx-plugin`、`docker-compose-plugin`、`docker-ce-rootless-extras`、`docker-model-plugin`
4. `systemctl enable --now docker` 自动启动，当前用户加入 `docker` 组
5. 自动配置 `/etc/docker/daemon.json` 的 `registry-mirrors`（docker pull 镜像加速）

## 参数

| 参数 | 说明 |
| --- | --- |
| `--version <VERSION>` | 指定版本，如 `--version 27.3` 或 `--version 27.3.1` |
| `--mirror <URL>` | 指定 GitHub 加速前缀（默认自动探测 ghfast.top / gh-proxy.com 等） |
| `--registry-mirror <URL>` | 追加一个 docker 镜像加速地址（可重复） |
| `--no-registry-mirror` | 跳过 registry 镜像加速配置 |
| `--no-autostart` | 不自动启动 docker 服务 |
| `--dry-run` | 只打印将要执行的步骤 |
| `--help` | 帮助 |

环境变量与参数等效：`VERSION`、`DOWNLOAD_MIRROR`、`REGISTRY_MIRRORS`（逗号分隔）、
`NO_AUTOSTART`、`NO_REGISTRY_MIRROR`、`PROJECT`、`TAG`。

示例：

```bash
# 指定版本安装
curl -fsSL https://github.com/MinimaxFlora/Docker_Private_source/raw/refs/heads/master/install.sh -o install.sh
sudo bash install.sh --version 27.3

# 指定加速前缀 + 追加镜像加速
sudo bash install.sh --mirror https://ghfast.top --registry-mirror https://docker.m.daocloud.io
```

## 支持的发行版与架构

| 发行版 | 代号 | 架构 |
| --- | --- | --- |
| Debian 13 | trixie | amd64, arm64 |
| Debian 12 | bookworm | amd64, arm64 |
| Debian 11 | bullseye | amd64, arm64 |
| Ubuntu 24.04 | noble | amd64, arm64 |
| Ubuntu 22.04 | jammy | amd64, arm64 |
| Ubuntu 20.04 | focal | amd64, arm64 |

## 工作原理

```
┌─────────────────────────── GitHub Actions（每周 + 手动触发）──────────────────────────┐
│  download.docker.com ──► 下载 docker-ce 家族 .deb（每包保留最近 3 个版本）              │
│       │                    amd64 / arm64 × 6 个发行版代号                               │
│       ▼                                                                               │
│  apt-ftparchive 重新生成 Packages 索引 + Release                                        │
│       │                    ▲                                                          │
│       ▼                    └── 本项目 GPG 私钥签名 InRelease / Release.gpg             │
│  打包 docker-ce-repo-<codename>.tar + SHA256（每个发行版一个独立资产）                   │
│       │                                                                               │
│       ▼                                                                               │
│  GitHub Release（固定 tag: latest，每次覆盖上传）── ghproxy 等镜像只代理 release 下载 ✓ │
└───────────────────────────────────────────────────────────────────────────────────────┘
        │
        ▼  国内机器
   install.sh ──► 加速下载 + SHA256 校验 ──► 本地 file: apt 源（signed-by 本项目公钥）
        └──► apt-get install docker-ce ... ──► 启动服务 / docker 组 / registry 加速
```

安全模型：安装包内容与官方 docker-ce 仓库完全一致（不重新打包 .deb），apt 通过
`Release/InRelease` 的 GPG 签名（本项目密钥）验证仓库完整性，下载过程另加 SHA256 双重校验。

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
5. 之后每周一自动同步；也可以在 docker 发新版后手动触发

## 常见问题

- **apt 报 `InRelease` 校验失败**：仓库签名密钥与公钥不匹配。确认 Secrets 中
  `GPG_PRIVATE_KEY` / `GPG_PASSPHRASE` 与仓库内 `public-key.asc` 出自同一次生成。
- **下载慢 / 失败**：`--mirror https://你的加速前缀` 手动指定；加速站列表见脚本内
  `DEFAULT_MIRRORS`。
- **想装旧版本**：仓库保留每包最近 3 个版本，`--version` 指定即可（如 `--version 24.0`）。
- **registry 镜像失效**：镜像加速站时效性强，用 `--registry-mirror` 追加或直接编辑
  `/etc/docker/daemon.json` 后 `systemctl restart docker`。

## License

[MIT](./LICENSE)
