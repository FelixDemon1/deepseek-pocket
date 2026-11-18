#!/usr/bin/env bash
# 根据 config.json 生成一键接入二维码 → data/qr.png（网关会自动在首页展示）
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f config.json ]] || { echo "缺少 config.json，先运行 ./deploy.sh"; exit 1; }
mkdir -p data

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi
.venv/bin/pip install --quiet --disable-pip-version-check qrcode pillow

LINK=$(.venv/bin/python - <<'PY'
import json, urllib.parse
cfg = json.load(open("config.json"))
base = cfg.get("public_base_url") or ("http://" + cfg.get("listen", "127.0.0.1:8787"))
if not base.endswith("/v1"):
    base += "/v1"
models = cfg.get("models") or ["deepseek-chat"]
print("deepseekgo://setup?" + urllib.parse.urlencode(
    {"base": base, "model": models[0], "name": "公益网关"}))
PY
)

.venv/bin/python -c "import qrcode,sys; qrcode.make(sys.argv[1]).save('data/qr.png')" "$LINK"
echo "已生成 data/qr.png"
echo "$LINK"
