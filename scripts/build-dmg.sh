#!/bin/bash
#
# Builds OpenClicky.app and packages OpenClicky.dmg on your own Mac.
# Same steps as .github/workflows/build-macos.yml, no GitHub needed.
#
# Requirements: macOS with Xcode 26 or newer (xcode-select pointing at it),
# and internet on the first run so Xcode can fetch Sparkle and whisper.cpp.
#
# Usage:  ./scripts/build-dmg.sh
# Output: ./OpenClicky.dmg
#
# The app is ad-hoc signed. After installing, open it via
# System Settings → Privacy & Security → Open Anyway (first launch only).
set -euo pipefail

cd "$(dirname "$0")/.."
PROJECT_ROOT="$(pwd)"
DERIVED_DATA_PATH="$PROJECT_ROOT/build"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/OpenClicky.app"
DMG_STAGING_PATH="$PROJECT_ROOT/build/dmg-contents"
DMG_OUTPUT_PATH="$PROJECT_ROOT/OpenClicky.dmg"

XCODE_MAJOR_VERSION=$(xcodebuild -version | head -1 | sed -E 's/Xcode ([0-9]+).*/\1/')
if [ "$XCODE_MAJOR_VERSION" -lt 26 ]; then
  echo "OpenClicky needs Xcode 26 or newer (found Xcode $XCODE_MAJOR_VERSION)."
  echo "Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi

echo "▶ Building OpenClicky (Release, universal)..."
xcodebuild \
  -project leanring-buddy.xcodeproj \
  -scheme leanring-buddy \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ENABLE_HARDENED_RUNTIME=NO \
  build | tee "$DERIVED_DATA_PATH-xcodebuild.log" | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

if [ ! -d "$APP_PATH" ]; then
  echo "✖ Build failed. Full log: $DERIVED_DATA_PATH-xcodebuild.log"
  exit 1
fi

echo "▶ Packaging OpenClicky.dmg..."
rm -rf "$DMG_STAGING_PATH" "$DMG_OUTPUT_PATH"
mkdir -p "$DMG_STAGING_PATH"
cp -R "$APP_PATH" "$DMG_STAGING_PATH/"
ln -s /Applications "$DMG_STAGING_PATH/Applications"
hdiutil create -volname "OpenClicky" -srcfolder "$DMG_STAGING_PATH" -ov -format UDZO "$DMG_OUTPUT_PATH" > /dev/null

echo "✔ Done: $DMG_OUTPUT_PATH"
echo "  Open it, drag OpenClicky to Applications, then open it from Applications."
