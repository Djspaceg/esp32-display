#!/bin/zsh
# Compile ESPDisplayAudio.driver into the bundle path given, unsigned. Shared
# by build-driver.sh (developers) and embed-driver.sh (the app's build).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="${1:?usage: compile-driver.sh <path/ESPDisplayAudio.driver>}"
IDENTITY_CONFIG="$HERE/../ESPDisplaySender/ESPDisplay.xcconfig"
[[ "$BUNDLE" == /*/ESPDisplayAudio.driver ]] || {
  echo "error: not an absolute ESPDisplayAudio.driver path: $BUNDLE" >&2
  exit 1
}
[[ -f "$IDENTITY_CONFIG" ]] || {
  echo "error: missing app identity settings at $IDENTITY_CONFIG" >&2
  exit 1
}
APP_BUNDLE_IDENTIFIER="$(sed -n \
  's/^APP_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*//p' "$IDENTITY_CONFIG")"
[[ -n "$APP_BUNDLE_IDENTIFIER" && "$APP_BUNDLE_IDENTIFIER" != *$'\n'* ]] || {
  echo "error: expected one app bundle identifier in $IDENTITY_CONFIG" >&2
  exit 1
}
AUDIO_DRIVER_BUNDLE_ID="$APP_BUNDLE_IDENTIFIER.audio-driver"

rm -rf -- "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$HERE/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$AUDIO_DRIVER_BUNDLE_ID" \
  "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  "-DESPDISP_AUDIO_BUNDLE_ID=\"$AUDIO_DRIVER_BUNDLE_ID\"" \
  -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  -o "$BUNDLE/Contents/MacOS/ESPDisplayAudio" \
  "$HERE/ESPDisplayAudio.c"
