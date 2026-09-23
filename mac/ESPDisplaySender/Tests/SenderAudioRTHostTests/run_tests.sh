#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SOURCE="$ROOT/Sources/SenderAudioRT/AudioCaptureRing.c"
INCLUDE="$ROOT/Sources/SenderAudioRT/include"
TEST="$HERE/test_audio_capture_ring.c"
TMP="$(mktemp -d)"
trap 'find "$TMP" -depth -delete' EXIT

COMMON=(
  -std=c11
  -Wall
  -Wextra
  -Werror
  -pedantic
  -pthread
  -I"$INCLUDE"
  "$TEST"
  "$SOURCE"
)

run_lane() {
  local name="$1"
  shift
  local output="$TMP/$name"
  echo "AudioCaptureRing $name: compile"
  clang "${COMMON[@]}" "$@" -o "$output"
  echo "AudioCaptureRing $name: run"
  "$output"
}

run_lane optimized -O2
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
  run_lane asan-ubsan \
    -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
TSAN_OPTIONS=halt_on_error=1 \
  run_lane tsan \
    -O1 -g -fsanitize=thread -fno-omit-frame-pointer
