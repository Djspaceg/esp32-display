#!/bin/zsh
# Build an isolated Local Network permission test beside the production app.
# It uses a distinct app identity and omits the camera extension; it does not
# launch either app.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
exec env ESPDISP_LAN_TEST_APP=1 "$HERE/make-app.sh"
