#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUTPUT_PATH="${1:-$HOME/Applications/AudioDelay.app}"

# The output path is recursively replaced below; refuse anything that is not
# unmistakably an app bundle so a mistyped argument cannot erase a directory.
case "$OUTPUT_PATH" in
  *.app) ;;
  *) echo "❌ Output path must end in .app (got: $OUTPUT_PATH)" >&2; exit 1 ;;
esac

mkdir -p "$(dirname "$OUTPUT_PATH")"

# Build both architectures and merge them, so one bundle runs on Apple Silicon and
# Intel. `swift build --arch a --arch b` needs full Xcode; building each slice against
# its own triple works with the Command Line Tools alone.
DEPLOYMENT_TARGET="13.0"
BIN="$SCRIPT_DIR/.build/AudioDelay-universal"
SLICES=()

for triple in arm64-apple-macosx x86_64-apple-macosx; do
  arch="${triple%%-*}"
  echo "Building ${arch}…"
  if swift build -c release --triple "${triple}${DEPLOYMENT_TARGET}" >/dev/null 2>&1; then
    SLICES+=("$SCRIPT_DIR/.build/${triple}/release/AudioDelay")
  else
    echo "⚠️  Could not build $arch; the app will not run on that architecture."
  fi
done

if [ ${#SLICES[@]} -lt 2 ] && [ "${ALLOW_SINGLE_ARCH:-0}" != "1" ]; then
  echo "❌ Universal build needs both architectures. Set ALLOW_SINGLE_ARCH=1 to build anyway." >&2
  exit 1
fi
if [ ${#SLICES[@]} -eq 0 ]; then
  echo "❌ No architecture built successfully" >&2
  exit 1
fi

mkdir -p "$(dirname "$BIN")"
lipo -create "${SLICES[@]}" -output "$BIN"

if [ ! -f "$BIN" ]; then
  echo "❌ Could not find compiled binary at $BIN" >&2
  exit 1
fi

# Regenerate the icon if it is missing; it is drawn from make-icon.swift.
if [ ! -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
  echo "Generating app icon…"
  "$SCRIPT_DIR/make-icon.swift" >/dev/null
fi

rm -rf "$OUTPUT_PATH"
mkdir -p "$OUTPUT_PATH/Contents/MacOS" "$OUTPUT_PATH/Contents/Resources"

VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "1.0")"

cat > "$OUTPUT_PATH/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>AudioDelay</string>
  <key>CFBundleIdentifier</key>
  <string>com.jaibri.audiodelay</string>
  <key>CFBundleName</key>
  <string>AudioDelay</string>
  <key>CFBundleDisplayName</key>
  <string>AudioDelay</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>AudioDelay reads audio from BlackHole to apply your configured delay before sending it to your speakers.</string>
</dict>
</plist>
PLIST

cp "$BIN" "$OUTPUT_PATH/Contents/MacOS/AudioDelay"
chmod +x "$OUTPUT_PATH/Contents/MacOS/AudioDelay"
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$OUTPUT_PATH/Contents/Resources/AppIcon.icns"

# Ad-hoc codesign so TCC has a stable identity for the bundle (otherwise unsigned
# binaries can get silently denied microphone access).
codesign --force --deep --sign - "$OUTPUT_PATH" >/dev/null 2>&1

ARCHS="$(lipo -archs "$OUTPUT_PATH/Contents/MacOS/AudioDelay" 2>/dev/null || echo "unknown")"
echo "✅ Built AudioDelay $VERSION at $OUTPUT_PATH ($ARCHS)"
