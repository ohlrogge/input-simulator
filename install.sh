#!/bin/bash
set -e

echo "==> Checking Xcode developer tools…"
DEVDIR=$(xcode-select -p 2>/dev/null || true)
if [[ "$DEVDIR" != *"Xcode.app"* ]]; then
    echo "    ERROR: xcode-select is pointing at '$DEVDIR' instead of Xcode."
    echo "    Fix:   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
echo "    OK: $DEVDIR"

echo ""
echo "==> Building InputSimulator (Release)…"
BUILD_LOG=$(xcodebuild -project InputSimulator.xcodeproj \
  -scheme InputSimulator \
  -configuration Release \
  CONFIGURATION_BUILD_DIR=./build \
  build 2>&1)
BUILD_STATUS=$?
echo "$BUILD_LOG" | grep -E "(error:|warning:|\*\* BUILD)" || true
if [ $BUILD_STATUS -ne 0 ]; then
    echo "    ERROR: build failed — run xcodebuild manually for full output"
    exit 1
fi
echo "    Build complete: ./build/InputSimulator.app"

echo ""
echo "==> Installing InputSimulator.app to ~/Applications…"
echo "    Quitting running instance (if any)…"
pkill -x InputSimulator || true
sleep 0.5
echo "    Removing old version…"
rm -rf ~/Applications/InputSimulator.app
echo "    Copying new version…"
cp -r ./build/InputSimulator.app ~/Applications/
echo "    Installed: ~/Applications/InputSimulator.app"

echo ""
echo "==> Launching InputSimulator…"
open ~/Applications/InputSimulator.app
echo "    Launched."

echo ""
echo "==> Done."
echo "    If this is a fresh install, grant Accessibility permission:"
echo "    System Settings → Privacy & Security → Accessibility → enable InputSimulator"
