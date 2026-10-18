## ✨ 版本化 Release

- Release 标签改为 `v<docker-ce 版本>`（例如 `v29.7.2`），不再滚动覆盖 `latest`
- 安装脚本默认通过 GitHub 的 `releases/latest/download` 获取最新版本化 Release
- 需要固定或回滚 Docker 版本时：`sudo bash install.sh --tag v29.7.2`
- 只保留最近 6 个版本，旧 Release 自动清理

### 安装

```bash
# 最新版本
curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh | sudo bash

# 固定 Release
curl -fsSL https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh -o install.sh
sudo bash install.sh --tag v29.7.2
```

### 支持范围

- **apt**：Debian 11/12/13（bullseye / bookworm / trixie）、Ubuntu 20.04/22.04/24.04（focal / jammy / noble），amd64 / arm64
- **rpm**：CentOS 7/9/10、Rocky 9/10、RHEL 9/10、AlmaLinux 9/10、Fedora 43/44（x86_64 / aarch64）

### 可靠性与安全

- GitHub Actions 每天同步官方 docker-ce 仓库（也可手动触发）
- **GPG 重签名**：仓库包用本项目私钥签名，apt `signed-by` / dnf `repo_gpgcheck` 校验
- SHA256 双重校验 + Release 资产「先删后传」绕开 CDN 缓存
- 每包保留最近 3 个版本，支持 `--version` 指定包版本
- 自动清理历史 workflow 运行记录
