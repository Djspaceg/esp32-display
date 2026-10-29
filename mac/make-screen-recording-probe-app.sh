#!/bin/zsh
# Build an isolated Screen Recording diagnostic beside ESPDisplaySender.
# It has a distinct identity and one button that calls CoreGraphics directly.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec env ESPDISP_SCREEN_RECORDING_PROBE_APP=1 "$HERE/make-app.sh"
