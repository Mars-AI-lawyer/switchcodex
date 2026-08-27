#!/usr/bin/env bash
# SwitchCodex 构建脚本：swiftc 编译 → 组装 .app → ad-hoc 签名 → 安装到 /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SwitchCodex"
BUILD_DIR="build"
BUNDLE="$BUILD_DIR/$APP_NAME.app"
ARCH="$(uname -m)"

echo "[1/4] 编译 Swift (arch: $ARCH)..."
mkdir -p "$BUILD_DIR"
swiftc -O -target "$ARCH-apple-macos13.0" \
    Sources/main.swift \
    -o "$BUILD_DIR/$APP_NAME"

echo "[2/4] 组装 $APP_NAME.app..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"
cp Assets/models.json "$BUNDLE/Contents/Resources/models.json"
cp Assets/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
cp Assets/menu-gpt.svg Assets/menu-deepseek.svg Assets/menu-bigmodel.svg "$BUNDLE/Contents/Resources/"

echo "[3/4] ad-hoc 签名..."
codesign --force -s - "$BUNDLE"

echo "[4/4] 安装到 /Applications..."
cp -R "$BUNDLE" /Applications/

echo ""
echo "完成：/Applications/$APP_NAME.app"
echo "双击启动（菜单栏出现图标），或在终端执行 open /Applications/$APP_NAME.app"
