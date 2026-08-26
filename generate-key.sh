#!/usr/bin/env bash
# =============================================================================
# 生成 apt 仓库签名用 GPG 密钥对（只在本机/受信环境运行一次）
#
# 用法:
#   ./generate-key.sh [名字] [邮箱]
#   # 或通过环境变量提供口令:  GPG_PASSPHRASE=xxxx ./generate-key.sh
#
# 生成后:
#   public-key.asc   -> 提交到仓库根目录（脚本打包进仓库，供 apt 校验）
#   gpg-private.key  -> 私钥，绝不要提交！内容粘贴到 GitHub Secrets
# =============================================================================
set -euo pipefail

NAME="${1:-docker-ce-cn}"
EMAIL="${2:-docker-ce-cn@kejizero.xyz}"
OUT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "${GPG_PASSPHRASE:-}" ]; then
    read -rsp "输入密钥口令（留空则自动生成随机口令）: " GPG_PASSPHRASE
    echo
fi
[ -n "$GPG_PASSPHRASE" ] || GPG_PASSPHRASE="$(openssl rand -base64 24)"

echo ">>> 生成 RSA-4096 签名密钥: $NAME <$EMAIL> ..."
gpg --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
    --quick-gen-key "$NAME <$EMAIL>" rsa4096 sign 0

FPR="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^sec:/{print $5; exit}')"
echo ">>> 密钥指纹: $FPR"

gpg --armor --export "$FPR" > "$OUT_DIR/public-key.asc"
gpg --batch --pinentry-mode loopback --passphrase "$GPG_PASSPHRASE" \
    --armor --export-secret-keys "$FPR" > "$OUT_DIR/gpg-private.key"
chmod 600 "$OUT_DIR/gpg-private.key"

cat <<EOF

============================================================================
  密钥已生成完毕！

  1. 将 public-key.asc 提交到仓库根目录（本脚本已在仓库内）
  2. 打开 GitHub 仓库 → Settings → Secrets and variables → Actions，新增:
       GPG_PRIVATE_KEY  = $(cat "$OUT_DIR/gpg-private.key" | head -c 0)（gpg-private.key 的完整内容）
       GPG_PASSPHRASE   = $GPG_PASSPHRASE
  3. 推送后手动运行 Actions 工作流（sync-docker-ce → Run workflow）验证
  4. 妥善备份 gpg-private.key 和口令；gpg-private.key 已被 .gitignore 排除
============================================================================
EOF
