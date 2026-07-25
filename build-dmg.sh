#!/bin/bash
set -euo pipefail

# Builds a distributable AudioDelay.dmg: the app plus an Applications symlink, so
# installing is a drag from one side of the window to the other.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "1.0")"
DIST_DIR="$SCRIPT_DIR/dist"
STAGE_DIR="$(mktemp -d)"
APP_PATH="$STAGE_DIR/AudioDelay.app"
DMG_PATH="$DIST_DIR/AudioDelay-${VERSION}.dmg"

cleanup() { rm -rf "$STAGE_DIR"; }
trap cleanup EXIT

# Build straight into the staging folder so the DMG never picks up a stale bundle
# from a previous run.
"$SCRIPT_DIR/build-app.sh" "$APP_PATH" >/dev/null
echo "✅ Built AudioDelay $VERSION ($(lipo -archs "$APP_PATH/Contents/MacOS/AudioDelay"))"

ln -s /Applications "$STAGE_DIR/Applications"

# A short read-me visible in the mounted volume, for the Gatekeeper prompt that an
# unsigned app triggers on first launch.
cat > "$STAGE_DIR/READ ME FIRST.txt" <<'TXT'
AudioDelay
==========

1. Drag AudioDelay onto the Applications folder shown here.

2. This app is not notarized by Apple, so the first launch needs one extra step.

   macOS 15 (Sequoia) and later: open AudioDelay once and dismiss the warning,
   then open System Settings > Privacy & Security, scroll down, and click
   "Open Anyway".

   macOS 13-14: open Applications, RIGHT-CLICK AudioDelay, choose "Open",
   then confirm.

   If macOS still refuses, run this in Terminal:
       xattr -cr /Applications/AudioDelay.app

3. On first launch AudioDelay offers to install BlackHole, a free open-source
   audio driver by Existential Audio. macOS gives apps no way to capture system
   audio without one. Click Install and it handles the download; your admin
   password is required because drivers install system-wide.

4. When you first turn the delay on, macOS asks for Microphone permission.
   Allow it: reading from BlackHole counts as audio input. AudioDelay never
   touches your real microphone.

AudioDelay lives in the menu bar, not the Dock. Look for the waveform icon.
TXT

if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
  cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$STAGE_DIR/.VolumeIcon.icns"
  SetFile -a C "$STAGE_DIR" 2>/dev/null || true
fi

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "AudioDelay" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  -quiet \
  "$DMG_PATH"

SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo "✅ Wrote $DMG_PATH ($SIZE)"
