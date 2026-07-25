#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  for candidate in "/Applications/AudioDelay.app" "$HOME/Applications/AudioDelay.app"; do
    if [ -d "$candidate" ]; then APP_PATH="$candidate"; break; fi
  done
  APP_PATH="${APP_PATH:-/Applications/AudioDelay.app}"
fi
if [ ! -d "$APP_PATH" ]; then
  echo "❌ Couldn't find app bundle at $APP_PATH. Install it first (or pass the path)." >&2
  exit 1
fi

osascript - "$APP_PATH" <<'OSA'
on run argv
  set appPath to POSIX file (item 1 of argv)
  tell application "System Events"
    if login item "AudioDelay" exists then
      delete login item "AudioDelay"
    end if
    make login item at end with properties {name:"AudioDelay", path:appPath, hidden:true}
  end tell
end run
OSA

echo "✅ Added AudioDelay to Login Items"
