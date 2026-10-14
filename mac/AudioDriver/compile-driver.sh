#!/bin/zsh
# Compile ESPDisplayAudio.driver into the bundle path given, unsigned. Shared
# by build-driver.sh (developers) and embed-driver.sh (the app's build).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="${1:?usage: compile-driver.sh <path/ESPDisplayAudio.driver>}"
[[ "$BUNDLE" == /*/ESPDisplayAudio.driver ]] || {
  echo "error: not an absolute ESPDisplayAudio.driver path: $BUNDLE" >&2
  exit 1
}

rm -rf -- "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$HERE/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
clang -std=c11 -O2 -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  -o "$BUNDLE/Contents/MacOS/ESPDisplayAudio" \
  "$HERE/ESPDisplayAudio.c"
