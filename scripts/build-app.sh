#!/bin/zsh
# Builds ClipboardX.app (default: ./build) and signs it. SIGN_IDENTITY: certificate hash/name (default: ad-hoc).
# APP_DIR overrides the output bundle path.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product ClipboardX
APP="${APP_DIR:-build/ClipboardX.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClipboardX "$APP/Contents/MacOS/ClipboardX"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.emintontul.clipboardx</string>
  <key>CFBundleName</key><string>ClipboardX</string>
  <key>CFBundleDisplayName</key><string>ClipboardX</string>
  <key>CFBundleExecutable</key><string>ClipboardX</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --verbose=1 "$APP"
echo "built $APP"
