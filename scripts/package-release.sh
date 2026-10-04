#!/bin/zsh
# Packages an ad-hoc signed, Apple Silicon build as dist/ClipboardX-<version>-arm64.dmg plus a SHA-256 file.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: package-release.sh <version>}"
rm -rf dist && mkdir -p dist/dmg-root
APP_DIR="dist/dmg-root/ClipboardX.app" SIGN_IDENTITY="-" ./scripts/build-app.sh
ln -s /Applications dist/dmg-root/Applications
DMG="dist/ClipboardX-${VERSION}-arm64.dmg"
hdiutil create -quiet -volname "ClipboardX" -srcfolder dist/dmg-root -format UDZO -ov "$DMG"
( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "packaged $DMG"; cat "$DMG.sha256"
