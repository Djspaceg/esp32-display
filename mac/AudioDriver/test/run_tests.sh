#!/usr/bin/env bash
# Host tests for ESPDisplayAudio.driver. Nothing is installed: the driver is
# exercised through its plug-in interface with a fake host, built three ways
# (optimized, ASan+UBSan, TSan), and an unsigned copy of the bundle is loaded
# through CFPlugIn as coreaudiod would.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DRIVER="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'find "$TMP" -depth -delete' EXIT

COMMON=(
  -std=c11 -Wall -Wextra -Werror -pthread
  -DESPDISP_AUDIO_DRIVER_TESTING
  -framework CoreAudio -framework CoreFoundation
  "$HERE/test_driver.c" "$DRIVER/ESPDisplayAudio.c"
)

run_lane() {
  local name="$1"
  shift
  echo "ESPDisplayAudio $name: compile"
  clang "${COMMON[@]}" "$@" -o "$TMP/$name"
  echo "ESPDisplayAudio $name: run"
  "$TMP/$name"
}

run_lane optimized -O2
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1 \
  run_lane asan-ubsan -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
TSAN_OPTIONS=halt_on_error=1 \
  run_lane tsan -O1 -g -fsanitize=thread -fno-omit-frame-pointer

echo "ESPDisplayAudio bundle-load: build"
BUNDLE="$TMP/ESPDisplayAudio.driver"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$DRIVER/Info.plist" "$BUNDLE/Contents/Info.plist"
clang -std=c11 -O2 -Wall -Wextra -Werror -bundle -fvisibility=hidden \
  -framework CoreAudio -framework CoreFoundation \
  -o "$BUNDLE/Contents/MacOS/ESPDisplayAudio" "$DRIVER/ESPDisplayAudio.c"
clang -std=c11 -Wall -Wextra -Werror -framework CoreAudio -framework CoreFoundation \
  -o "$TMP/bundle-load" "$HERE/test_bundle_load.c"
echo "ESPDisplayAudio bundle-load: run"
"$TMP/bundle-load" "$BUNDLE"
