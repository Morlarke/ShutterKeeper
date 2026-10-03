#!/bin/bash
#
# 把命令行工具构建出的可执行文件打包成 macOS 应用（.app）。
#
# 用法：
#   Scripts/build-app.sh            # release 构建
#   Scripts/build-app.sh debug      # debug 构建
#
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="快门闪选"
BUNDLE_ID="com.shutterkeeper.app"
VERSION="beta-0.11"
BUILD_NUMBER="1"
AUTHOR="快门镖局-陈师"
CONTACT="thechengsir@foxmail.com"

# 一般情况下不需要设置。只在受限环境（例如被沙盒限制的工具进程）里构建时，
# 可以传：SK_SWIFT_FLAGS="--disable-sandbox --cache-path ... --scratch-path ..."
sk_swift() {
    # shellcheck disable=SC2086
    swift "$@" ${SK_SWIFT_FLAGS:-}
}

echo "==> 构建可执行文件（${CONFIGURATION}）"
sk_swift build -c "$CONFIGURATION" --product ShutterKeeper
BIN_DIR="$(sk_swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/ShutterKeeper" "$CONTENTS/MacOS/ShutterKeeper"

# 应用图标：源图在 Assets/AppIcon-source.png，改过就重新生成
ICON_SOURCE="$ROOT/Assets/AppIcon-source.png"
ICON_FILE="$ROOT/build/AppIcon.icns"
if [[ -f "$ICON_SOURCE" ]]; then
    if [[ ! -f "$ICON_FILE" || "$ICON_SOURCE" -nt "$ICON_FILE" ]]; then
        echo "==> 生成应用图标"
        swift "$ROOT/Scripts/make-icon.swift" "$ICON_SOURCE" "$ICON_FILE"
    fi
    cp "$ICON_FILE" "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>ShutterKeeper</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.photography</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 ${AUTHOR} · ${CONTACT}</string>
    <key>CFBundleGetInfoString</key>
    <string>${APP_NAME} ${VERSION} — ${AUTHOR}（${CONTACT}）</string>
    <key>SKAuthor</key>
    <string>${AUTHOR}</string>
    <key>SKContact</key>
    <string>${CONTACT}</string>
</dict>
</plist>
PLIST

if command -v codesign >/dev/null 2>&1; then
    echo "==> ad-hoc 签名"
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "   （签名跳过，不影响本机运行）"
fi

echo "==> 完成：$APP_DIR"
echo "    运行：open \"$APP_DIR\""
