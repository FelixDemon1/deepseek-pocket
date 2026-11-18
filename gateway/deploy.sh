#!/usr/bin/env bash
# 一条命令把公益网关跑起来：./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f config.json ]]; then
  ADMIN=$(openssl rand -hex 24)
  sed "s|change-me-to-a-long-random-string|$ADMIN|" config.example.json > config.json
  echo "已生成 config.json，管理令牌：$ADMIN"
  echo "!! 请把 upstream_keys 换成你自己的 sk-，并把 public_base_url 改成你的域名，然后重新执行本脚本"
  exit 1
fi

mkdir -p data
./scripts/make-qr.sh || echo "（二维码生成失败，可稍后单独运行 ./scripts/make-qr.sh）"

if command -v docker >/dev/null 2>&1; then
  docker compose up -d --build
  echo "网关已启动：http://127.0.0.1:8787"
  echo "首页（一键配置页）：http://127.0.0.1:8787/"
else
  echo "未检测到 docker，直接用 go 跑："
  go build -o dsggw . && ./dsggw -config config.json
fi
