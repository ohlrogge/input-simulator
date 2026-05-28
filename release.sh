#!/bin/bash
set -e

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

echo "==> Checking Xcode developer tools…"
DEVDIR=$(xcode-select -p 2>/dev/null || true)
if [[ "$DEVDIR" != *"Xcode.app"* ]]; then
    echo "    ERROR: xcode-select is pointing at '$DEVDIR' instead of Xcode."
    echo "    Fix:   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    exit 1
fi
echo "    OK: $DEVDIR"

echo ""
echo "==> Checking gh CLI…"
if ! command -v gh &>/dev/null; then
    echo "    ERROR: gh not found. Install from https://cli.github.com"
    exit 1
fi
if ! gh auth status &>/dev/null; then
    echo "    ERROR: gh is not authenticated. Run: gh auth login"
    exit 1
fi
echo "    OK"

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

echo ""
echo "==> Determining next version…"
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
IFS='.' read -r major minor patch <<< "${LAST_TAG#v}"
NEXT_TAG="v${major}.${minor}.$((patch + 1))"
echo "    Last release: $LAST_TAG  →  Next: $NEXT_TAG"
echo ""
read -r -p "    Use $NEXT_TAG? (enter to confirm, or type a different tag): " OVERRIDE
if [[ -n "$OVERRIDE" ]]; then
    NEXT_TAG="$OVERRIDE"
fi
echo "    Releasing as: $NEXT_TAG"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Install locally
# ---------------------------------------------------------------------------

echo ""
echo "==> Installing to ~/Applications…"
echo "    Quitting running instance (if any)…"
pkill -x InputSimulator || true
sleep 0.5
rm -rf ~/Applications/InputSimulator.app
cp -r ./build/InputSimulator.app ~/Applications/
echo "    Installed: ~/Applications/InputSimulator.app"

echo ""
echo "==> Launching InputSimulator…"
open ~/Applications/InputSimulator.app
echo "    Launched."

# ---------------------------------------------------------------------------
# Release notes
# ---------------------------------------------------------------------------

echo ""
echo "==> Preparing release notes…"
echo "    Commits since $LAST_TAG:"
git log "${LAST_TAG}..HEAD" --oneline | sed 's/^/      /'

NOTES_FILE=$(mktemp /tmp/release_notes_XXXXXX.md)
cat > "$NOTES_FILE" <<TEMPLATE
**Bug fixes**

-

**New**

-

**Updating from a previous version**

Before replacing the app, remove it from *System Settings → Privacy & Security → Accessibility* and re-add it after the update — macOS ties the permission to the binary, so the old entry will no longer match the new build.
TEMPLATE

echo ""
echo "    Opening release notes in \${EDITOR:-nano}…"
${EDITOR:-nano} "$NOTES_FILE"

# ---------------------------------------------------------------------------
# Tag, zip, publish
# ---------------------------------------------------------------------------

echo ""
echo "==> Tagging $NEXT_TAG and pushing…"
git tag "$NEXT_TAG"
git push origin "$NEXT_TAG"
echo "    Tag pushed."

echo ""
echo "==> Creating zip…"
ZIP_PATH="/tmp/InputSimulator.zip"
rm -f "$ZIP_PATH"
cd ~/Applications && zip -r "$ZIP_PATH" InputSimulator.app -q
cd - > /dev/null
echo "    Created: $ZIP_PATH"

echo ""
echo "==> Publishing GitHub release $NEXT_TAG…"
gh release create "$NEXT_TAG" "$ZIP_PATH" \
  --title "$NEXT_TAG" \
  --notes-file "$NOTES_FILE"

rm -f "$NOTES_FILE"

echo ""
echo "==> Done. Release published:"
gh release view "$NEXT_TAG" --json url --jq '.url'
