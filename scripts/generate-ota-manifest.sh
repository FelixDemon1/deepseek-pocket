#!/usr/bin/env bash
# Generates an Apple OTA (`itms-services://`) manifest.plist + 1-click install.html landing page
# Usage: bash scripts/generate-ota-manifest.sh https://your-domain.com/releases
set -euo pipefail

BASE_URL="${1:-https://example.com/releases}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

cat > "$DIST_DIR/manifest.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${BASE_URL}/DeepSeekGo-signed.ipa</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>io.deepseekgo.ios</string>
        <key>bundle-version</key>
        <string>1.0.0</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>DeepSeek Go</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
EOF

cat > "$DIST_DIR/install.html" <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>安装 DeepSeek Go (iOS)</title>
  <style>
    body{margin:0;background:#fff;color:#111827;font-family:-apple-system,BlinkMacSystemFont,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:24px;box-sizing:border-box}
    .box{max-width:380px;width:100%;text-align:center}
    .logo{width:72px;height:72px;border-radius:20px;background:#4D6BFE;margin:0 auto 18px;box-shadow:0 10px 24px rgba(77,107,254,.25)}
    h1{font-size:24px;margin:0 0 8px}
    p{color:#6B7485;font-size:14px;line-height:1.5;margin:0 0 24px}
    a.btn{display:block;padding:14px 18px;border-radius:14px;text-decoration:none;font-weight:600;font-size:15px;margin-bottom:10px}
    .primary{background:#4D6BFE;color:#fff}
    .secondary{background:#F6F8FC;color:#111827;border:1px solid #E2E8F0}
  </style>
</head>
<body>
  <div class="box">
    <div class="logo"></div>
    <h1>DeepSeek Go</h1>
    <p>兼容 iOS 17 / 18 / 26 / 27 全系设备 · 纯原生零遥测</p>
    <a class="btn primary" href="itms-services://?action=download-manifest&url=${BASE_URL}/manifest.plist">网页一键直装 (已签 Ad-Hoc / 企业包)</a>
    <a class="btn secondary" href="sidestore://install?url=${BASE_URL}/DeepSeekGo-unsigned.ipa">一键导入 SideStore 自动重签</a>
    <a class="btn secondary" href="altstore://install?url=${BASE_URL}/DeepSeekGo-unsigned.ipa">一键导入 AltStore 自动重签</a>
    <a class="btn secondary" href="${BASE_URL}/DeepSeekGo-unsigned.ipa">下载未签名 IPA (巨魔 TrollStore / 签名工具)</a>
  </div>
</body>
</html>
EOF

echo "Generated $DIST_DIR/manifest.plist and $DIST_DIR/install.html"
