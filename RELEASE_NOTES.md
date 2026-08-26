## ✨ v1.0 更新内容

### 🆕 新增：国内网络自动适配

- 自动检测国内/海外网络：**国内**优先使用 `gh-proxy.kejizero.xyz` 加速站下载仓库包，**海外**直连 GitHub（可用 `--mirror` 或环境变量 `CHINA_MIRROR` 自定义加速站）
- registry 镜像加速按网络判定：国内默认配置（docker.1ms.run 等），海外跳过（直连 Docker Hub 更快）
- 已安装检测：重复执行直接显示 Docker 版本与服务状态并退出，不重复下载；`--force` 强制重装/升级

### 🎯 支持范围

- **apt**：Debian 11/12/13（bullseye / bookworm / trixie）、Ubuntu 20.04/22.04/24.04（focal / jammy / noble），amd64 / arm64
- **rpm**：CentOS 7/9/10、Rocky 9/10、RHEL 9/10、AlmaLinux 9/10、Fedora 43/44（x86_64 / aarch64）

### 🛠 可靠性与安全

- GitHub Actions 定时同步官方 docker-ce 仓库（每天 + 手动触发，可分别运行 deb / rpm）
- **GPG 重签名**：仓库包用本项目私钥签名，apt `signed-by` / dnf `repo_gpgcheck` 校验
- SHA256 双重校验 + Release 资产「先删后传」绕开 CDN 缓存
- 每包保留最近 3 个版本，支持 `--version` 指定版本安装
- 自动清理历史 workflow 运行记录

### 📌 历史版本

- v1.0：初始版本，同步官方 docker-ce 仓库并 GPG 重签名分发（国内一键安装 Docker）
