#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DIR="$ROOT_DIR/build/DerivedData"
DIST_DIR="$ROOT_DIR/dist"

echo "==> [1/3] Running Swift 6 Core Security & Engine Tests..."
(cd "$ROOT_DIR/Packages/DeepSeekKit" && swift test)

echo "==> [2/3] Compiling Release iOS App (iphoneos arm64, unsigned)..."
xcodebuild \
  -project "$ROOT_DIR/DeepSeekGo.xcodeproj" \
  -scheme DeepSeekGo \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DIR" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -n 20

APP_PATH="$DERIVED_DIR/Build/Products/Release-iphoneos/DeepSeekGo.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: Expected app bundle not found at $APP_PATH" >&2
  exit 1
fi

echo "==> [3/3] Packaging DeepSeekGo-unsigned.ipa..."
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/Payload"
cp -R "$APP_PATH" "$DIST_DIR/Payload/"
(cd "$DIST_DIR" && ditto -c -k --keepParent Payload DeepSeekGo-unsigned.ipa && rm -rf Payload)

IPA_SIZE="$(du -h "$DIST_DIR/DeepSeekGo-unsigned.ipa" | cut -f1)"
echo "SUCCESS: $DIST_DIR/DeepSeekGo-unsigned.ipa ($IPA_SIZE)"
